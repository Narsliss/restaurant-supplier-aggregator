class OrdersController < ApplicationController
  include DeliveryDatesRefresher

  before_action :require_organization!
  before_action :set_order, only: [:show, :edit, :update, :destroy, :submit, :cancel, :reorder, :placement_status, :retry_order, :mark_received, :mark_unreceived]
  before_action :require_operator!, only: [:new, :create, :edit, :update, :destroy, :submit, :reorder, :select_list]

  def select_list
    org = current_user.current_organization
    return @aggregated_lists = AggregatedList.none, @order_lists = [], @empty = true unless org

    # Promoted org-wide matched list (shown prominently)
    @promoted_list = AggregatedList.for_organization(org).promoted.matched_lists.first

    # Location-scoped matched lists (fallback when no promoted list)
    base = AggregatedList.for_organization(org).matched_lists
    base = base.where.not(id: @promoted_list.id) if @promoted_list
    if chef? && current_location
      base = base.where(location_id: current_location.id)
    end
    @aggregated_lists = base.includes(supplier_lists: :supplier).order(updated_at: :desc)

    # Order lists for this location
    @order_lists = scoped_order_lists
      .includes(:order_list_items)
      .recent

    @empty = @promoted_list.nil? && @aggregated_lists.empty? && @order_lists.empty?
  end

  # Status groups exposed via the ?status= filter on Order History.
  # Each bucket maps to a distinct chef action — collapsing only happens where
  # chefs don't distinguish (verifying ≈ processing; the three submit-ready
  # states all share a single submit click).
  # Cancelled is intentionally excluded from the default view — only visible when
  # explicitly filtered to "cancelled".
  STATUS_FILTER_GROUPS = {
    "drafts"        => %w[draft],
    "price_changed" => %w[price_changed],
    "waiting"       => %w[pending pending_review pending_manual],
    "processing"    => %w[verifying processing],
    "completed"     => %w[submitted confirmed dry_run_complete],
    "failed"        => %w[failed],
    "cancelled"     => %w[cancelled]
  }.freeze

  # Statuses pulled into the default Order History view regardless of date
  # range or batch membership — anything the chef might still need to act on.
  OPEN_STATUSES = (
    STATUS_FILTER_GROUPS["drafts"] +
    STATUS_FILTER_GROUPS["price_changed"] +
    STATUS_FILTER_GROUPS["waiting"] +
    STATUS_FILTER_GROUPS["processing"] +
    STATUS_FILTER_GROUPS["failed"]
  ).freeze

  def index
    @date_from = params[:date_from].present? ? Date.parse(params[:date_from]) : 30.days.ago.to_date
    @date_to = params[:date_to].present? ? Date.parse(params[:date_to]) : Date.current
    @status_filter = params[:status].to_s.presence
    @status_filter = nil unless STATUS_FILTER_GROUPS.key?(@status_filter)

    # KPI cards always reflect "completed orders in date range" so they remain
    # meaningful regardless of which status the list below is filtered to.
    kpi_scope = apply_common_filters(
      scoped_orders.where(status: STATUS_FILTER_GROUPS["completed"])
    ).where(submitted_at: @date_from.beginning_of_day..@date_to.end_of_day)

    @total_savings = kpi_scope.sum(:savings_amount)
    @total_spent = kpi_scope.sum(:total_amount)
    @order_count = kpi_scope.count

    all_orders = if @status_filter
      build_filtered_list(@status_filter)
    else
      build_default_list
    end

    # Group by batch_id (the actual submission session) first — each checkout creates one batch.
    # Fall back to order_list_id for legacy orders without a batch_id, then to standalone per-order.
    @order_groups = all_orders.group_by { |o| o.batch_id || o.order_list_id || "standalone_#{o.id}" }
      .values
      .sort_by { |group| group.map { |o| o.submitted_at || o.draft_saved_at || o.created_at }.compact.max || Time.at(0) }
      .reverse

    @suppliers = Supplier.joins(:orders)
      .merge(scoped_orders.where(status: STATUS_FILTER_GROUPS["completed"]))
      .distinct.order(:name)
  end

  def show
    @items = @order.order_items.includes(supplier_product: [:supplier, :product])
    @validations = @order.order_validations.order(validated_at: :desc)

    # Order minimum (blocking) — skip if supplier was deleted
    @minimum = @order.supplier&.order_minimum(@order.location)
    @meets_minimum = @minimum.nil? || (@order.subtotal || 0) >= (@minimum || 0)

    # Case minimum (blocking)
    @case_minimum = @order.supplier&.case_minimum(@order.location)
    @case_count = @order.item_count
    @meets_case_minimum = @case_minimum.nil? || @case_count >= @case_minimum
  end

  def new
    @order_list = scoped_order_lists.find(params[:order_list_id]) if params[:order_list_id]
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
      @order = Order.new(user: current_user, organization: current_user.current_organization, location: current_location)
      @order_lists = scoped_order_lists.recent
      @suppliers = Supplier.active.where(
        id: scoped_credentials.active.select(:supplier_id)
      )
    end
  end

  def create
    @order_list = scoped_order_lists.find(params[:order][:order_list_id])
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
      redirect_to @order
    rescue ArgumentError => e
      redirect_to new_order_path(order_list_id: @order_list.id)
    end
  end

  def edit
    redirect_to @order unless @order.pending?
  end

  def update
    if @order.editable? && @order.update(order_params)
      @order.recalculate_totals!
      respond_to do |format|
        format.html { redirect_to @order }
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
    if @order.can_delete?
      @order.destroy
      redirect_to orders_path, notice: "Order deleted."
    else
      redirect_to @order, alert: "Cannot delete a submitted order."
    end
  end

  def submit
    unless @order.can_submit?
      redirect_to @order
      return
    end

    # Queue the order placement job
    PlaceOrderJob.perform_later(
      @order.id,
      accept_price_changes: params[:accept_price_changes] == "true",
      skip_warnings: params[:skip_warnings] == "true"
    )

    @order.update!(status: "processing")
    redirect_to @order
  end

  def cancel
    if @order.cancel!
      redirect_to @order
    else
      redirect_to @order
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
      redirect_to @order
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

    redirect_to order_path(@order)
  end

  def mark_received
    @order.mark_received!
    redirect_back fallback_location: order_path(@order), notice: "Order marked as received."
  end

  def mark_unreceived
    @order.mark_unreceived!
    redirect_back fallback_location: order_path(@order), notice: "Received status cleared."
  end

  # Reorder: clone a completed order's items into a new pending order at current prices
  def reorder
    if @order.processing?
      redirect_to @order
      return
    end

    batch_id = SecureRandom.uuid
    new_order = nil

    ActiveRecord::Base.transaction do
      new_order = Order.create!(
        user: current_user,
        organization: current_user.current_organization,
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
      redirect_to @order
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

    # Optional order list context (unified builder)
    order_list = params[:order_list_id].present? ? scoped_order_lists.find_by(id: params[:order_list_id]) : nil

    service = Orders::AggregatedListOrderService.new(
      user: current_user,
      aggregated_list: aggregated_list,
      quantities: quantities,
      supplier_overrides: params[:supplier_overrides] || {},
      uom_overrides: params[:uom_overrides] || {},
      location: current_location,
      delivery_date: params[:delivery_date],
      order_list: order_list
    )

    orders, batch_id = service.create_pending_orders!

    builder_path = order_list ?
      order_builder_aggregated_list_path(aggregated_list, order_list_id: order_list.id) :
      order_builder_aggregated_list_path(aggregated_list)

    if orders.any?
      # If this submission came from "Continue Adding Items" on an existing draft/batch,
      # the old batch's in-progress orders are now stale — remove them so the user doesn't see
      # duplicates in Order History. We only do this AFTER the new batch is confirmed created.
      if params[:previous_batch_id].present? && params[:previous_batch_id] != batch_id
        scoped_orders.for_batch(params[:previous_batch_id])
                     .where(status: %w[pending verifying price_changed draft])
                     .destroy_all
      end

      redirect_to review_orders_path(batch_id: batch_id, aggregated_list_id: aggregated_list.id),
        notice: "#{orders.size} order(s) ready for review across #{orders.map { |o| o.supplier.name }.join(', ')}."
    else
      redirect_to builder_path,
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
      redirect_to orders_path
      return
    end

    @batch_id = params[:batch_id]
    @aggregated_list_id = params[:aggregated_list_id]
    @orders = scoped_orders
      .for_batch(@batch_id)
      .where(status: %w[pending verifying price_changed draft])
      .includes(:supplier, :location, order_items: { supplier_product: :product })

    # If no aggregated_list_id was passed (e.g., resume from Order History),
    # infer one the user can actually access so "Continue Adding Items" works. Prefer:
    #   (1) a matched list tied to the batch's location
    #   (2) an org-wide promoted matched list
    #   (3) any matched list in the org the user can see
    if @aggregated_list_id.blank?
      order_location = @orders.first&.location
      order_org = @orders.first&.organization || order_location&.organization || current_user.current_organization
      if order_org
        scope = AggregatedList.for_organization(order_org).matched_lists
        inferred = (order_location && scope.where(location_id: order_location.id).first) ||
                   scope.promoted.first ||
                   scope.first
        @aggregated_list_id = inferred&.id
      end
    end

    if @orders.empty?
      # Check if they've all been submitted already
      submitted = scoped_orders.for_batch(@batch_id).where(status: %w[processing submitted confirmed])
      if submitted.any?
        redirect_to batch_progress_orders_path(batch_id: @batch_id)
      else
        redirect_to orders_path
      end
      return
    end

    # Touch draft_saved_at on every draft order in this batch — this resets the auto-expiry
    # timer, so chefs revisiting a draft via "Return to Checkout" keep it alive another window.
    drafts_in_batch = @orders.select(&:draft?)
    if drafts_in_batch.any?
      Order.where(id: drafts_in_batch.map(&:id)).update_all(draft_saved_at: Time.current)
    end

    # Re-verify draft orders only if prices are stale (verified > 1 hour ago).
    # Skip orders where verification already failed OR was skipped (e.g., 2FA supplier needing
    # re-login, maintenance) — those need manual retry, not auto-retry loops.
    # Also skip orders with price_changed status (user must review/accept changes manually).
    draft_orders_to_reverify = @orders.select { |o|
      o.draft? &&
        !o.verification_status.in?(%w[failed skipped price_changed]) &&
        (o.price_verified_at.nil? || o.price_verified_at < 1.hour.ago)
    }
    draft_orders_to_reverify.each do |order|
      # Clear stale delivery dates so the chef must pick a new one
      if order.delivery_date.present? && order.delivery_date <= Date.current
        order.update!(delivery_date: nil)
      end

      if order.supplier.email_supplier?
        order.update!(verification_status: 'skipped')
        order.mark_as_draft!
      else
        order.start_verification!
        PriceVerificationJob.perform_later(order.id)
      end
    end

    # Auto-start verification for any pending orders that haven't been verified yet
    orders_needing_verification = @orders.select { |o| o.pending? && o.verification_status.nil? }
    if orders_needing_verification.any?
      orders_needing_verification.each do |order|
        if order.supplier.email_supplier?
          # Email suppliers use saved prices — skip verification, mark as ready
          order.update!(verification_status: 'skipped')
          order.mark_as_draft!
        else
          order.start_verification!
          PriceVerificationJob.perform_later(order.id)
        end
      end
    end

    # No reload needed — start_verification! already updated the in-memory objects

    # Check if any are currently verifying (for UI state). Use verification_status as the
    # source of truth — order.status can get stuck at "verifying" after a skip/fail, which
    # would keep the inline poll script alive and show a misleading banner.
    @verifying = @orders.any? { |o| o.verification_status.in?(%w[pending verifying]) }
    @has_price_changes = @orders.any?(&:price_changed?)

    # Build review data for each order
    @review_orders = @orders.map do |order|
      minimum = order.supplier.order_minimum(order.location)
      meets_minimum = minimum.nil? || (order.subtotal || 0) >= minimum

      # Case minimum (blocking)
      case_min = order.supplier.case_minimum(order.location)
      current_case_count = order.item_count
      meets_case_minimum = case_min.nil? || current_case_count >= case_min

      suggestions = if !meets_minimum || !meets_case_minimum
        Orders::MinimumSuggestionService.new(user: current_user, order: order).suggestions
      else
        []
      end

      # Check if the current user has credentials for this supplier
      # Email suppliers don't need credentials — they're ordered via email/export
      # Uses scoped_credentials which respects org/role/location visibility
      has_credentials = order.supplier.email_supplier? || scoped_credentials.where(
        supplier: order.supplier
      ).where.not(status: %w[expired failed]).exists?

      {
        order: order,
        supplier: order.supplier,
        items: order.order_items,
        subtotal: order.subtotal || order.calculated_subtotal,
        item_count: order.order_items.size,
        minimum: minimum,
        meets_minimum: meets_minimum,
        amount_to_minimum: minimum ? [minimum - (order.subtotal || 0), 0].max : 0,
        case_minimum: case_min,
        case_count: current_case_count,
        meets_case_minimum: meets_case_minimum,
        cases_to_minimum: case_min ? [case_min - current_case_count, 0].max : 0,
        savings: order.savings_amount || 0,
        verification_status: order.verification_status,
        verified_total: order.verified_total,
        price_change_amount: order.price_change_amount,
        verification_error: order.verification_error,
        suggestions: suggestions,
        has_credentials: has_credentials
      }
    end

    @summary = {
      order_count: @orders.size,
      total_items: @review_orders.sum { |r| r[:item_count] },
      total_amount: @review_orders.sum { |r| r[:subtotal] },
      total_savings: @review_orders.sum { |r| r[:savings] },
      all_minimums_met: @review_orders.all? { |r| r[:meets_minimum] && r[:meets_case_minimum] }
    }

    # Delivery schedule data for per-order date validation
    supplier_ids = @orders.map(&:supplier_id).uniq
    @delivery_schedules_by_supplier = SupplierDeliverySchedule
      .where(supplier_id: supplier_ids, active: true)
      .for_location(current_location)
      .order(:day_of_week)
      .group_by(&:supplier_id)

    api_capable_credentials = scoped_credentials.active
                                                .where(supplier_id: supplier_ids)
                                                .includes(:supplier)
                                                .to_a
    @api_delivery_dates_by_supplier = {}
    api_capable_credentials.each do |cred|
      next if cred.available_delivery_dates.blank?

      @api_delivery_dates_by_supplier[cred.supplier_id] = cred.available_delivery_dates
    end

    # Auto-refresh stale API delivery dates (Sysco today). Runs async — the
    # current page uses whatever's cached; the next page load picks up the
    # refreshed values. See FetchSyscoDeliveryDatesJob for the freshness
    # window and dedupe behavior.
    refresh_stale_delivery_dates!(api_capable_credentials)
  end

  # Search supplier products for the "Forgot Something?" modal on the review page.
  # Returns products from suppliers that have pending orders in the batch.
  def search_products
    query = params[:q].to_s.strip
    batch_id = params[:batch_id]

    if query.length < 3 || batch_id.blank?
      render json: { results: [] }
      return
    end

    # Find which suppliers have pending/draft orders in this batch
    supplier_ids = scoped_orders
      .for_batch(batch_id)
      .where(status: %w[pending verifying price_changed draft])
      .pluck(:supplier_id)
      .uniq

    # Search supplier products from those suppliers
    results = SupplierProduct
      .where(supplier_id: supplier_ids)
      .available
      .in_stock
      .where("supplier_name ILIKE ?", "%#{query}%")
      .includes(:supplier)
      .order(:supplier_name)
      .map do |sp|
        order = scoped_orders
          .for_batch(batch_id)
          .where(supplier_id: sp.supplier_id, status: %w[pending verifying price_changed draft])
          .first

        {
          id: sp.id,
          name: sp.supplier_name,
          sku: sp.supplier_sku,
          pack_size: sp.pack_size,
          price: sp.current_price,
          supplier_name: sp.supplier.name,
          supplier_id: sp.supplier_id,
          order_id: order&.id
        }
      end
      .select { |r| r[:order_id].present? }

    render json: { results: results }
  end

  # Submit all pending orders in a batch.
  # Prices are already verified on the review page — goes straight to PlaceOrderJob.
  # SAFETY: Never calls submit!/scraper directly.
  def submit_batch
    batch_id = params[:batch_id]
    order_ids = params[:order_ids] # optional: submit specific orders only

    # Accept orders that are draft (verified), pending, or have accepted price changes
    orders = scoped_orders.for_batch(batch_id).where(status: %w[pending price_changed draft])

    if order_ids.present?
      orders = orders.where(id: order_ids)
    end

    if orders.empty?
      # Check if orders exist but are already submitted/processing
      existing = scoped_orders.for_batch(batch_id)
      existing = existing.where(id: order_ids) if order_ids.present?
      already_submitted = existing.where(status: %w[processing submitted confirmed])
      if already_submitted.any?
        redirect_to already_submitted.size == 1 ? order_path(already_submitted.first) : batch_progress_orders_path(batch_id: batch_id)
      else
        redirect_to orders_path, alert: "No orders ready to submit."
      end
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

    # Server-side credential check — filter out orders the user can't place
    # Email suppliers don't need credentials (ordered via email/export)
    user_supplier_ids = scoped_credentials.where.not(status: %w[expired failed]).pluck(:supplier_id)
    submittable, skipped = orders.partition { |o| o.supplier.email_supplier? || user_supplier_ids.include?(o.supplier_id) }

    if submittable.empty?
      supplier_names = skipped.map { |o| o.supplier.name }.uniq.join(", ")
      redirect_to review_orders_path(batch_id: batch_id, aggregated_list_id: params[:aggregated_list_id]),
        alert: "You don't have credentials for: #{supplier_names}. Please connect your account before ordering."
      return
    end

    orders = submittable

    # Accept any price changes and proceed directly to placement.
    # Stagger jobs by 15s each to avoid overwhelming the worker with
    # concurrent Chromium instances (which causes browser hydration failures).
    orders.each_with_index do |order, index|
      order.accept_price_changes! if order.price_changed?
      order.update!(status: "processing", error_message: nil, confirmation_number: nil)
      delay = index * 15.seconds
      if delay.zero?
        PlaceOrderJob.perform_later(order.id)
      else
        PlaceOrderJob.set(wait: delay).perform_later(order.id)
      end
    end

    # Single order: redirect to show page so user sees real-time processing status
    # Multiple orders: redirect to batch progress page for real-time tracking
    if orders.size == 1
      redirect_to order_path(orders.first)
    else
      redirect_to batch_progress_orders_path(batch_id: batch_id)
    end
  end

  # JSON endpoint for polling verification status from the review page
  def verification_status
    batch_id = params[:batch_id]
    orders = scoped_orders.for_batch(batch_id)
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

      # Items added after verification that are still being verified (verified_price is nil)
      unverified_items = order.order_items.select { |item| item.verified_price.nil? }.map do |item|
        {
          id: item.id,
          name: item.supplier_product&.supplier_name,
          sku: item.supplier_sku
        }
      end

      # Items that just completed verification (verified_price was set by VerifyItemPriceJob)
      newly_verified_items = order.order_items
        .select { |item| item.verified_price.present? && !items_with_changes.any? { |c| c[:id] == item.id } }
        .select { |item| item.verified_price == item.unit_price }
        .map { |item| { id: item.id } }

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
        unverified_items: unverified_items,
        newly_verified_items: newly_verified_items,
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
        saved_as_draft: all_complete && orders.any?(&:draft?),
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

    orders = scoped_orders.for_batch(batch_id).where(status: "price_changed")
    orders = orders.where(id: order_ids) if order_ids.present?

    if orders.empty?
      render json: { error: "No orders with price changes found." }, status: :unprocessable_entity
      return
    end

    orders.each_with_index do |order, index|
      order.accept_price_changes!
      order.update!(status: "processing")
      delay = index * 15.seconds
      if delay.zero?
        PlaceOrderJob.perform_later(order.id)
      else
        PlaceOrderJob.set(wait: delay).perform_later(order.id)
      end
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

    orders = scoped_orders.for_batch(batch_id)
      .where(status: %w[pending verifying price_changed draft])
    orders = orders.where(id: order_ids) if order_ids.present?

    # Only re-verify non-email suppliers
    verifiable = orders.reject { |o| o.supplier.email_supplier? }
    verifiable.each do |order|
      order.start_verification!
      PriceVerificationJob.perform_later(order.id)
    end

    render json: {
      success: true,
      message: "Retrying verification for #{verifiable.size} order(s)..."
    }
  end

  # Skip verification — marks orders as skipped so user can review and submit manually
  def skip_verification
    batch_id = params[:batch_id]
    order_ids = params[:order_ids] || []

    orders = scoped_orders.for_batch(batch_id)
      .where(status: %w[verifying price_changed draft])
      .or(scoped_orders.for_batch(batch_id).where(verification_status: "failed"))
    orders = orders.where(id: order_ids) if order_ids.present?

    orders.each do |order|
      order.skip_verification!
      order.mark_as_draft!
    end

    render json: {
      success: true,
      message: "Verification skipped for #{orders.size} order(s). Ready to submit."
    }
  end

  # Split order - preview
  def split_preview
    @order_list = scoped_order_lists.find(params[:order_list_id])
    @service = Orders::SplitOrderService.new(@order_list, location: current_location)
    @preview = @service.preview
  end

  # Split order - create all orders
  def split_create
    @order_list = scoped_order_lists.find(params[:order_list_id])
    delivery_date = params[:delivery_date]

    service = Orders::SplitOrderService.new(@order_list, location: current_location)

    begin
      @orders = service.create_orders!(delivery_date: delivery_date)

      if params[:submit_immediately] == "true"
        service.submit_all!(@orders)
        redirect_to orders_path
      else
        redirect_to orders_path
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
      redirect_to orders_path
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

  # Apply supplier_id and search filters that all index scopes share.
  def apply_common_filters(relation)
    relation = relation.where(supplier_id: params[:supplier_id]) if params[:supplier_id].present?
    if params[:search].present?
      search_term = "%#{params[:search]}%"
      relation = relation.where(
        "CAST(orders.id AS TEXT) LIKE ? OR confirmation_number LIKE ?",
        search_term, search_term
      )
    end
    relation
  end

  # Default Order History list: completed orders within the date range, plus
  # every draft and every actionable order (pending/verifying/price_changed/
  # processing/pending_review/pending_manual/failed) regardless of date or
  # batch membership. Cancelled orders are hidden unless filtered to.
  def build_default_list
    completed = apply_common_filters(scoped_orders.where(status: STATUS_FILTER_GROUPS["completed"]))
      .where(submitted_at: @date_from.beginning_of_day..@date_to.end_of_day)
      .includes(:supplier, :location, :order_items, :order_list, :user)
      .order(submitted_at: :desc)
      .to_a

    open_orders = apply_common_filters(scoped_orders.where(status: OPEN_STATUSES))
      .where.not(id: completed.map(&:id))
      .includes(:supplier, :location, :order_items, :order_list, :user)
      .to_a

    completed + open_orders
  end

  # Targeted view when ?status= is set. Date range only applies to "completed".
  def build_filtered_list(status_key)
    relation = apply_common_filters(scoped_orders.where(status: STATUS_FILTER_GROUPS[status_key]))
    if status_key == "completed"
      relation = relation.where(submitted_at: @date_from.beginning_of_day..@date_to.end_of_day)
    end
    relation
      .includes(:supplier, :location, :order_items, :order_list, :user)
      .order(Arel.sql("COALESCE(submitted_at, draft_saved_at, created_at) DESC"))
      .to_a
  end

  def set_order
    @order = scoped_orders.find(params[:id])
  end

  def order_params
    params.require(:order).permit(:location_id, :notes, :delivery_date)
  end

  def find_batch_orders
    if params[:batch_id].present?
      scoped_orders.for_batch(params[:batch_id])
    elsif params[:order_list_id].present?
      scoped_orders.where(order_list_id: params[:order_list_id])
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
