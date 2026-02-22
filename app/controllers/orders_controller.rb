class OrdersController < ApplicationController
  before_action :set_order, only: [:show, :edit, :update, :destroy, :submit, :cancel, :reorder, :placement_status, :retry_order]

  def index
    orders_scope = current_user.orders
      .where(status: %w[submitted confirmed dry_run_complete])
      .includes(:supplier, :location, :order_items, :order_list)
      .order(submitted_at: :desc)

    # Default date range: last 30 days
    @date_from = params[:date_from].present? ? Date.parse(params[:date_from]) : 30.days.ago.to_date
    @date_to = params[:date_to].present? ? Date.parse(params[:date_to]) : Date.current

    orders_scope = orders_scope.where("submitted_at >= ?", @date_from.beginning_of_day)
    orders_scope = orders_scope.where("submitted_at <= ?", @date_to.end_of_day)

    # Filter by supplier
    if params[:supplier_id].present?
      orders_scope = orders_scope.where(supplier_id: params[:supplier_id])
    end

    # Search by order ID or confirmation number
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      orders_scope = orders_scope.where("CAST(orders.id AS TEXT) LIKE ? OR confirmation_number LIKE ?", search_term, search_term)
    end

    # KPI: total savings across filtered orders
    @total_savings = orders_scope.sum(:savings_amount)
    @total_spent = orders_scope.sum(:total_amount)
    @order_count = orders_scope.count

    # Group orders by order_list_id or batch_id for split/batch order display
    # Orders with same order_list_id were part of one split order
    # Orders with same batch_id were submitted together as a batch
    all_orders = orders_scope.to_a
    @order_groups = all_orders.group_by { |o| o.order_list_id || o.batch_id || "standalone_#{o.id}" }
      .values
      .sort_by { |group| group.map(&:submitted_at).compact.max || Time.at(0) }
      .reverse

    @suppliers = Supplier.joins(:orders)
      .where(orders: { user_id: current_user.id, status: %w[submitted confirmed dry_run_complete] })
      .distinct.order(:name)
  end

  def show
    @items = @order.order_items.includes(supplier_product: [:supplier, :product])
    @validations = @order.order_validations.order(validated_at: :desc)
  end

  def new
    @order_list = current_user.order_lists.find(params[:order_list_id]) if params[:order_list_id]
    @supplier = Supplier.find(params[:supplier_id]) if params[:supplier_id]

    if @order_list && @supplier
      builder = Orders::OrderBuilderService.new(
        user: current_user,
        order_list: @order_list,
        supplier: @supplier,
        location: current_location
      )
      @preview = builder.preview
      @order = builder.build
    else
      @order = current_user.orders.new
      @order_lists = current_user.order_lists.recent
      @suppliers = Supplier.active.where(
        id: current_user.supplier_credentials.active.select(:supplier_id)
      )
    end
  end

  def create
    @order_list = current_user.order_lists.find(params[:order][:order_list_id])
    @supplier = Supplier.find(params[:order][:supplier_id])
    delivery_date = params[:order][:delivery_date]

    builder = Orders::OrderBuilderService.new(
      user: current_user,
      order_list: @order_list,
      supplier: @supplier,
      location: current_location
    )

    begin
      @order = builder.build_and_save!
      @order.update!(
        delivery_date: delivery_date,
        notes: params[:order][:notes]
      )
      redirect_to @order, notice: "Order created. Review and submit when ready."
    rescue ArgumentError => e
      redirect_to new_order_path(order_list_id: @order_list.id), alert: e.message
    end
  end

  def edit
    redirect_to @order, alert: "Cannot edit submitted orders." unless @order.pending?
  end

  def update
    if @order.editable? && @order.update(order_params)
      @order.recalculate_totals!
      respond_to do |format|
        format.html { redirect_to @order, notice: "Order updated." }
        format.json { render json: { success: true, order: { id: @order.id, delivery_date: @order.delivery_date, notes: @order.notes } } }
      end
    else
      respond_to do |format|
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: { error: "Could not update order" }, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    if @order.pending?
      @order.destroy
      redirect_to orders_path, notice: "Order deleted."
    else
      redirect_to @order, alert: "Cannot delete submitted orders."
    end
  end

  def submit
    unless @order.can_submit?
      redirect_to @order, alert: "This order cannot be submitted."
      return
    end

    # Queue the order placement job
    PlaceOrderJob.perform_later(
      @order.id,
      accept_price_changes: params[:accept_price_changes] == "true",
      skip_warnings: params[:skip_warnings] == "true"
    )

    @order.update!(status: "processing")
    redirect_to @order, notice: "Order is being submitted..."
  end

  def cancel
    if @order.cancel!
      redirect_to @order, notice: "Order cancelled."
    else
      redirect_to @order, alert: "Cannot cancel this order."
    end
  end

  # JSON endpoint for show page polling while order is processing
  def placement_status
    render json: {
      id: @order.id,
      status: @order.status,
      processing: @order.processing?
    }
  end

  # Reset a failed order so the user can edit items and resubmit.
  # Removes any items marked unavailable during the failed attempt.
  def retry_order
    unless @order.failed?
      redirect_to @order, alert: "Only failed orders can be retried."
      return
    end

    # Remove items that were marked unavailable during the failed attempt
    @order.order_items.where(status: "unavailable").destroy_all

    # Reset order to pending so items can be edited
    @order.update!(
      status: "pending",
      error_message: nil,
      confirmation_number: nil
    )
    @order.recalculate_totals!

    redirect_to order_path(@order), notice: "Order reset — edit items below, then submit when ready."
  end

  # Reorder: clone a completed order's items into a new pending order at current prices
  def reorder
    if @order.processing?
      redirect_to @order, alert: "This order is still being processed."
      return
    end

    batch_id = SecureRandom.uuid
    new_order = nil

    ActiveRecord::Base.transaction do
      new_order = current_user.orders.create!(
        supplier: @order.supplier,
        location: current_location,
        status: "pending",
        batch_id: batch_id,
        subtotal: 0,
        total_amount: 0
      )

      skipped = []

      @order.order_items.includes(:supplier_product).each do |original_item|
        sp = original_item.supplier_product

        # Skip items that are discontinued or no longer priced
        if sp.nil? || sp.discontinued? || sp.current_price.nil?
          skipped << (sp&.supplier_name || "Unknown item")
          next
        end

        new_order.order_items.create!(
          supplier_product: sp,
          quantity: original_item.quantity,
          unit_price: sp.current_price,
          line_total: sp.current_price * original_item.quantity,
          status: "pending"
        )
      end

      new_order.recalculate_totals!

      if new_order.order_items.empty?
        raise ActiveRecord::Rollback
      end
    end

    if new_order.nil? || new_order.order_items.empty?
      redirect_to @order, alert: "None of the items from this order are currently available."
      return
    end

    redirect_to review_orders_path(batch_id: batch_id),
      notice: "New order created with #{new_order.order_items.count} items at current prices. Review and submit when ready."
  end

  # Create pending orders from an aggregated list's product matches
  # SAFETY: Only creates status: "pending" orders. Never submits.
  def create_from_aggregated_list
    aggregated_list = find_aggregated_list(params[:aggregated_list_id])
    quantities = params[:quantities] || {}

    service = Orders::AggregatedListOrderService.new(
      user: current_user,
      aggregated_list: aggregated_list,
      quantities: quantities,
      supplier_overrides: params[:supplier_overrides] || {},
      location: current_location,
      delivery_date: params[:delivery_date]
    )

    orders, batch_id = service.create_pending_orders!

    if orders.any?
      redirect_to review_orders_path(batch_id: batch_id, aggregated_list_id: aggregated_list.id),
        notice: "#{orders.size} order(s) ready for review across #{orders.map { |o| o.supplier.name }.join(', ')}."
    else
      redirect_to order_builder_aggregated_list_path(aggregated_list),
        alert: "No items selected. Set quantities for the items you want to order."
    end
  rescue => e
    redirect_to order_builder_aggregated_list_path(aggregated_list),
      alert: "Failed to create orders: #{e.message}"
  end

  # Review orders from a batch before submitting.
  # Automatically kicks off price verification for any pending orders.
  def review
    unless params[:batch_id].present?
      redirect_to orders_path, alert: "No batch specified."
      return
    end

    @batch_id = params[:batch_id]
    @aggregated_list_id = params[:aggregated_list_id]
    @orders = current_user.orders
      .for_batch(@batch_id)
      .where(status: %w[pending verifying price_changed])
      .includes(:supplier, order_items: { supplier_product: :product })

    if @orders.empty?
      # Check if they've all been submitted already
      submitted = current_user.orders.for_batch(@batch_id).where(status: %w[processing submitted confirmed])
      if submitted.any?
        redirect_to orders_path, notice: "All orders in this batch have been submitted."
      else
        redirect_to orders_path, alert: "No orders found for this batch."
      end
      return
    end

    # Auto-start verification for any pending orders that haven't been verified yet
    orders_needing_verification = @orders.select { |o| o.pending? && o.verification_status.nil? }
    if orders_needing_verification.any?
      orders_needing_verification.each do |order|
        order.start_verification!
        PriceVerificationJob.perform_later(order.id)
      end
    end

    # Reload to pick up status changes from start_verification!
    @orders.each(&:reload) if orders_needing_verification.any?

    # Check if any are currently verifying (for UI state)
    @verifying = @orders.any?(&:verifying?)
    @has_price_changes = @orders.any?(&:price_changed?)

    # Build review data for each order
    @review_orders = @orders.map do |order|
      minimum = order.supplier.order_minimum
      meets_minimum = minimum.nil? || (order.subtotal || 0) >= minimum

      suggestions = if !meets_minimum
        Orders::MinimumSuggestionService.new(user: current_user, order: order).suggestions
      else
        []
      end

      {
        order: order,
        supplier: order.supplier,
        items: order.order_items.includes(supplier_product: :product),
        subtotal: order.subtotal || order.calculated_subtotal,
        item_count: order.order_items.count,
        minimum: minimum,
        meets_minimum: meets_minimum,
        amount_to_minimum: minimum ? [minimum - (order.subtotal || 0), 0].max : 0,
        savings: order.savings_amount || 0,
        verification_status: order.verification_status,
        verified_total: order.verified_total,
        price_change_amount: order.price_change_amount,
        verification_error: order.verification_error,
        suggestions: suggestions
      }
    end

    @summary = {
      order_count: @orders.size,
      total_items: @review_orders.sum { |r| r[:item_count] },
      total_amount: @review_orders.sum { |r| r[:subtotal] },
      total_savings: @review_orders.sum { |r| r[:savings] },
      all_minimums_met: @review_orders.all? { |r| r[:meets_minimum] }
    }
  end

  # Submit all pending orders in a batch.
  # Prices are already verified on the review page — goes straight to PlaceOrderJob.
  # SAFETY: Never calls submit!/scraper directly.
  def submit_batch
    batch_id = params[:batch_id]
    order_ids = params[:order_ids] # optional: submit specific orders only

    # Accept orders that are pending (verified) or have accepted price changes
    orders = current_user.orders.for_batch(batch_id).where(status: %w[pending price_changed])

    if order_ids.present?
      orders = orders.where(id: order_ids)
    end

    if orders.empty?
      redirect_to orders_path, alert: "No pending orders found for this batch."
      return
    end

    # Validate all orders have a delivery date set (must be after today)
    missing_dates = orders.select { |o| o.delivery_date.blank? || o.delivery_date <= Date.current }
    if missing_dates.any?
      supplier_names = missing_dates.map { |o| o.supplier.name }.join(", ")
      redirect_to review_orders_path(batch_id: batch_id, aggregated_list_id: params[:aggregated_list_id]),
        alert: "Please set a delivery date (after today) for: #{supplier_names}"
      return
    end

    # Accept any price changes and proceed directly to placement
    orders.each do |order|
      order.accept_price_changes! if order.price_changed?
      order.update!(status: "processing", error_message: nil, confirmation_number: nil)
      PlaceOrderJob.perform_later(order.id)
    end

    # Single order: redirect to show page so user sees real-time processing status
    # Multiple orders: redirect to batch progress page for real-time tracking
    if orders.size == 1
      redirect_to order_path(orders.first), notice: "Order is being submitted to #{orders.first.supplier.name}..."
    else
      redirect_to batch_progress_orders_path(batch_id: batch_id), notice: "#{orders.size} orders are being submitted..."
    end
  end

  # JSON endpoint for polling verification status from the review page
  def verification_status
    batch_id = params[:batch_id]
    orders = current_user.orders.for_batch(batch_id)
      .includes(:supplier, order_items: :supplier_product)

    order_statuses = orders.map do |order|
      items_with_changes = order.order_items.select(&:verified_price_changed?).map do |item|
        {
          id: item.id,
          name: item.supplier_product.supplier_name,
          sku: item.supplier_sku,
          expected_price: item.unit_price.to_f,
          verified_price: item.verified_price.to_f,
          difference: item.verified_price_difference.to_f,
          change_percentage: item.verified_price_change_percentage
        }
      end

      # Include out-of-stock items so the review page can warn before submit
      unavailable_items = order.order_items.select { |item| item.supplier_product&.out_of_stock? }.map do |item|
        {
          id: item.id,
          name: item.supplier_product.supplier_name,
          sku: item.supplier_sku
        }
      end

      {
        id: order.id,
        supplier_name: order.supplier.name,
        status: order.status,
        verification_status: order.verification_status,
        subtotal: order.subtotal.to_f,
        verified_total: order.verified_total&.to_f,
        price_change_amount: order.price_change_amount&.to_f,
        price_change_percentage: order.price_change_percentage,
        verification_error: order.verification_error,
        price_verified_at: order.price_verified_at&.iso8601,
        items_with_changes: items_with_changes,
        unavailable_items: unavailable_items,
        supplier_delivery_address: order.supplier_delivery_address
      }
    end

    all_complete = orders.none?(&:verification_in_progress?)

    render json: {
      batch_id: batch_id,
      orders: order_statuses,
      summary: {
        total_orders: orders.size,
        verifying: orders.count(&:verification_in_progress?),
        verified: orders.count(&:prices_verified?),
        price_changed: orders.count(&:has_price_changes?),
        failed: orders.count(&:verification_failed?),
        processing: orders.count(&:processing?),
        all_complete: all_complete,
        any_price_changed: orders.any?(&:has_price_changes?),
        any_failed: orders.any?(&:verification_failed?),
        skipped: orders.count { |o| o.verification_status == "skipped" },
        all_clear: orders.all? { |o| o.prices_verified? || o.verification_status == "skipped" || o.processing? || o.submitted? || o.confirmed? }
      }
    }
  end

  # Accept price changes for specific orders and proceed to placement
  def accept_price_changes
    batch_id = params[:batch_id]
    order_ids = params[:order_ids] || []

    orders = current_user.orders.for_batch(batch_id).where(status: "price_changed")
    orders = orders.where(id: order_ids) if order_ids.present?

    if orders.empty?
      render json: { error: "No orders with price changes found." }, status: :unprocessable_entity
      return
    end

    orders.each do |order|
      order.accept_price_changes!
      order.update!(status: "processing")
      PlaceOrderJob.perform_later(order.id)
    end

    render json: {
      success: true,
      message: "#{orders.size} order(s) accepted with updated prices and submitted."
    }
  end

  # Retry verification for failed orders
  def retry_verification
    batch_id = params[:batch_id]
    order_ids = params[:order_ids] || []

    orders = current_user.orders.for_batch(batch_id).where(verification_status: "failed")
    orders = orders.where(id: order_ids) if order_ids.present?

    orders.each do |order|
      order.start_verification!
      PriceVerificationJob.perform_later(order.id)
    end

    render json: {
      success: true,
      message: "Retrying verification for #{orders.size} order(s)..."
    }
  end

  # Skip verification — marks orders as skipped so user can review and submit manually
  def skip_verification
    batch_id = params[:batch_id]
    order_ids = params[:order_ids] || []

    orders = current_user.orders.for_batch(batch_id)
      .where(status: %w[verifying price_changed])
      .or(current_user.orders.for_batch(batch_id).where(verification_status: "failed"))
    orders = orders.where(id: order_ids) if order_ids.present?

    orders.each do |order|
      order.skip_verification!
      order.update!(status: "pending") unless order.pending?
    end

    render json: {
      success: true,
      message: "Verification skipped for #{orders.size} order(s). Ready to submit."
    }
  end

  # Split order - preview
  def split_preview
    @order_list = current_user.order_lists.find(params[:order_list_id])
    @service = Orders::SplitOrderService.new(@order_list, location: current_location)
    @preview = @service.preview
  end

  # Split order - create all orders
  def split_create
    @order_list = current_user.order_lists.find(params[:order_list_id])
    delivery_date = params[:delivery_date]

    service = Orders::SplitOrderService.new(@order_list, location: current_location)

    begin
      @orders = service.create_orders!(delivery_date: delivery_date)

      if params[:submit_immediately] == "true"
        service.submit_all!(@orders)
        redirect_to orders_path, notice: "#{@orders.size} orders created and submitted to suppliers."
      else
        redirect_to orders_path, notice: "#{@orders.size} orders created. Review and submit when ready."
      end
    rescue Orders::SplitOrderService::OrderMinimumError => e
      redirect_to split_preview_orders_path(order_list_id: @order_list.id),
        alert: "#{e.supplier.name} minimum not met. Need $#{'%.2f' % e.minimum}, have $#{'%.2f' % e.current}."
    rescue => e
      redirect_to split_preview_orders_path(order_list_id: @order_list.id),
        alert: "Failed to create orders: #{e.message}"
    end
  end

  # Batch progress page — real-time tracking during submission + permanent batch detail view
  # Supports both batch_id (submit_batch) and order_list_id (split orders) grouping
  def batch_progress
    @batch_id = params[:batch_id]
    @order_list_id = params[:order_list_id]
    @orders = find_batch_orders
      .includes(:supplier, order_items: :supplier_product)
      .order(:id)

    if @orders.empty?
      redirect_to orders_path, alert: "No orders found for this batch."
      return
    end

    @any_processing = @orders.any?(&:processing?)
    @batch_total = @orders.sum { |o| o.total_amount || 0 }
    @batch_items = @orders.sum { |o| o.order_items.size }
  end

  # JSON endpoint for batch progress polling
  def batch_placement_status
    orders = find_batch_orders
      .includes(:supplier, order_items: :supplier_product)

    render json: {
      orders: orders.map { |o|
        {
          id: o.id,
          supplier_name: o.supplier.name,
          status: o.status,
          processing: o.processing?,
          total_amount: o.total_amount&.to_f,
          confirmation_number: o.confirmation_number,
          error_message: o.error_message,
          item_count: o.order_items.size
        }
      },
      all_complete: orders.none?(&:processing?)
    }
  end

  private

  def set_order
    @order = current_user.orders.find(params[:id])
  end

  def order_params
    params.require(:order).permit(:location_id, :notes, :delivery_date)
  end

  def find_batch_orders
    if params[:batch_id].present?
      current_user.orders.for_batch(params[:batch_id])
    elsif params[:order_list_id].present?
      current_user.orders.where(order_list_id: params[:order_list_id])
    else
      Order.none
    end
  end

  def find_aggregated_list(id)
    if current_user.current_organization
      AggregatedList.for_organization(current_user.current_organization).find(id)
    else
      current_user.created_aggregated_lists.find(id)
    end
  end
end
