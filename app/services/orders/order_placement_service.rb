module Orders
  class OrderPlacementService
    attr_reader :order, :scraper, :validation_result

    def initialize(order)
      @order = order
    end

    def place_order(accept_price_changes: false, skip_warnings: false, skip_pre_validation: false)
      # Step 1: Run pre-submission validations
      # (validate_item_availability may auto-remove out-of-stock items via destroy_all)
      validate_order!(skip_warnings: skip_warnings)

      # Reload association — validation may have removed OOS items from the DB,
      # but the in-memory association cache still holds the deleted records.
      order.order_items.reload
      order.recalculate_totals! if order.respond_to?(:recalculate_totals!)

      # Step 2: Run thorough pre-order validation (stock, price, minimum, delivery)
      unless skip_pre_validation
        pre_validation = run_pre_order_validation
        return pre_validation unless pre_validation[:proceed]
      end

      # Step 3: Get credentials
      credential = get_active_credential

      # Step 4: Initialize scraper
      @scraper = order.supplier.scraper_klass.new(credential)

      order.update!(status: 'processing')

      begin
        # Step 4: Clear any existing cart items, then add our items
        scraper.clear_cart if scraper.respond_to?(:clear_cart)
        cart_items = build_cart_items
        cart_result = scraper.add_to_cart(cart_items, delivery_date: order.delivery_date)

        # Handle items that couldn't be added (e.g., out of stock on supplier site)
        if cart_result.is_a?(Hash) && cart_result[:failed]&.any?
          handle_skipped_cart_items(cart_result[:failed])
        end

        # Re-check: if item removal dropped us below the order minimum, fail early
        recheck_order_minimum_after_removals!

        # Step 5: Attempt checkout (with dry_run if checkout not enabled for this supplier)
        dry_run = !order.supplier.checkout_enabled?
        result = scraper.checkout(dry_run: dry_run)

        # Step 6: Record result
        if result[:dry_run]
          order.update!(
            status: 'dry_run_complete',
            confirmation_number: result[:confirmation_number],
            total_amount: result[:total],
            submitted_at: Time.current,
            delivery_date: result[:delivery_date] || order.delivery_date,
            notes: [order.notes, dry_run_summary(result)].compact.join("\n\n")
          )
          order.order_items.update_all(status: 'pending')

          Rails.logger.info "[OrderPlacement] Order #{order.id} DRY RUN complete for #{order.supplier.name}"

          { success: true, order: order.reload, dry_run: true }
        else
          order.update!(
            status: 'submitted',
            confirmation_number: result[:confirmation_number],
            total_amount: result[:total],
            submitted_at: Time.current,
            delivery_date: result[:delivery_date]
          )
          order.order_items.update_all(status: 'added')

          Rails.logger.info "[OrderPlacement] Order #{order.id} submitted: #{result[:confirmation_number]}"

          { success: true, order: order.reload }
        end
      rescue Scrapers::BaseScraper::OrderMinimumError => e
        handle_order_minimum_error(e)
      rescue Scrapers::BaseScraper::ItemUnavailableError => e
        handle_item_unavailable_error(e)
      rescue Scrapers::BaseScraper::PriceChangedError => e
        handle_price_changed_error(e, accept_price_changes)
      rescue Scrapers::BaseScraper::AccountHoldError => e
        handle_account_hold_error(e)
      rescue Scrapers::BaseScraper::CaptchaDetectedError => e
        handle_captcha_error(e)
      rescue Scrapers::BaseScraper::DeliveryUnavailableError => e
        handle_delivery_error(e)
      rescue Authentication::TwoFactorHandler::TwoFactorRequired => e
        handle_2fa_required(e)
      rescue StandardError => e
        handle_generic_error(e)
      end
    end

    def retry_after_2fa(request)
      return unless request.verified?

      credential = request.supplier_credential
      @scraper = order.supplier.scraper_klass.new(credential)

      # Resume order placement
      place_order
    end

    private

    def dry_run_summary(result)
      lines = ["[DRY RUN — #{Time.current.strftime('%b %d, %Y %I:%M %p')}]"]
      lines << "Checkout flow completed without placing order."
      lines << "Extracted total: $#{'%.2f' % result[:total]}" if result[:total]

      # Detect surcharges/fees: compare our item subtotal to the platform's total
      our_subtotal = order.calculated_subtotal
      if result[:total] && result[:total] > our_subtotal && our_subtotal > 0
        difference = result[:total] - our_subtotal
        lines << "Item subtotal: $#{'%.2f' % our_subtotal}"
        lines << "⚠️  Platform surcharge/fees: $#{'%.2f' % difference} (below-minimum or delivery fee)"
      end

      lines << "Delivery date: #{result[:delivery_date]}" if result[:delivery_date]
      if result[:cart_items]&.any?
        lines << "Cart items verified: #{result[:cart_items].count}"
        result[:cart_items].each do |item|
          lines << "  - #{item['name']} (#{item['sku']}): qty #{item['quantity']} @ $#{item['price']}"
        end
      end
      lines.join("\n")
    end

    def run_pre_order_validation
      # Build a temporary order list from the order items for validation
      order_list = OrderList.new(
        user: order.user,
        organization: order.organization,
        name: 'Temp validation list'
      )

      # Copy order items to the list
      order.order_items.each do |order_item|
        order_list.order_list_items.build(
          supplier_product: order_item.supplier_product,
          quantity: order_item.quantity
        )
      end

      # Run pre-order validation
      validator = PreOrderValidationService.new(
        order_list: order_list,
        supplier: order.supplier,
        user: order.user,
        delivery_date: order.delivery_date
      )

      result = validator.validate!

      # Handle validation result
      unless result[:valid]
        error_messages = result[:errors].map { |e| e[:message] }.join('; ')
        order.update!(
          status: 'failed',
          error_message: "Pre-order validation failed: #{error_messages}"
        )

        Rails.logger.warn "[OrderPlacement] Order #{order.id} failed pre-validation: #{error_messages}"

        return {
          proceed: false,
          success: false,
          error_type: 'pre_validation_failed',
          error: error_messages,
          details: result[:errors]
        }
      end

      # Handle price changes
      if result[:price_changes].any? && !@accept_price_changes
        order.update!(
          status: 'pending_review',
          error_message: "#{result[:price_changes].count} item(s) have price changes. Review required."
        )

        Rails.logger.info "[OrderPlacement] Order #{order.id} pending review: price changes detected"

        return {
          proceed: false,
          success: false,
          error_type: 'price_changed',
          error: 'Prices have changed. Review required.',
          details: { price_changes: result[:price_changes] },
          requires_review: true
        }
      end

      # Handle 2FA requirement
      if result[:requires_2fa]
        order.update!(
          status: 'pending_manual',
          error_message: 'Two-factor authentication required to validate order.'
        )

        return {
          proceed: false,
          success: false,
          error_type: '2fa_required',
          error: 'Two-factor authentication required to validate order.'
        }
      end

      # Update order totals if prices changed
      update_order_with_pre_validation_prices(result[:price_changes]) if result[:price_changes].any?

      Rails.logger.info "[OrderPlacement] Order #{order.id} passed pre-validation"

      { proceed: true }
    rescue StandardError => e
      Rails.logger.error "[OrderPlacement] Pre-validation error: #{e.class} - #{e.message}"

      # Don't fail the order on validation error - proceed with caution
      { proceed: true, validation_error: e.message }
    end

    def update_order_with_pre_validation_prices(price_changes)
      price_changes.each do |change|
        order_item = order.order_items.find_by(id: change[:item_id])
        next unless order_item

        order_item.update!(
          unit_price: change[:new_price],
          line_total: change[:new_price] * order_item.quantity
        )
      end

      order.recalculate_totals!
    end

    def validate_order!(skip_warnings: false)
      validator = OrderValidationService.new(order)
      @validation_result = validator.validate!

      return if skip_warnings
      return unless validation_result[:warnings].any?

      warning_messages = validation_result[:warnings].map { |w| w[:message] }.join('; ')
      order.update!(
        status: 'pending_review',
        notes: "Warnings: #{warning_messages}"
      )
    end

    def get_active_credential
      credential = order.user.supplier_credentials.find_by(
        supplier: order.supplier,
        status: 'active'
      )

      unless credential
        order.update!(status: 'failed', error_message: "No active credentials for #{order.supplier.name}")
        raise OrderValidationService::ValidationError.new(
          errors: [{ type: 'no_credentials', message: "No active credentials for #{order.supplier.name}" }]
        )
      end

      credential
    end

    def build_cart_items
      order.order_items.includes(:supplier_product).map do |item|
        {
          sku: item.supplier_product.supplier_sku,
          name: item.supplier_product.supplier_name,
          quantity: item.quantity.to_i,
          expected_price: item.unit_price
        }
      end
    end

    def handle_order_minimum_error(error)
      difference = error.minimum - error.current_total

      order.update!(
        status: 'failed',
        error_message: "Order minimum not met. Minimum: #{format_currency(error.minimum)}, " \
                       "Current: #{format_currency(error.current_total)}. " \
                       "Add #{format_currency(difference)} more to proceed."
      )

      Rails.logger.warn "[OrderPlacement] Order #{order.id} failed: minimum not met"

      {
        success: false,
        error_type: 'order_minimum',
        error: error.message,
        details: {
          minimum: error.minimum,
          current_total: error.current_total,
          difference: difference
        }
      }
    end

    def handle_item_unavailable_error(error)
      item_names = error.items.map { |i| i[:name] }.compact.join(', ')

      order.update!(
        status: 'failed',
        error_message: "#{error.items.count} item(s) are unavailable: #{item_names}"
      )

      # Mark specific items as failed and update supplier product stock status
      error.items.each do |item|
        order_item = order.order_items.joins(:supplier_product)
                          .find_by(supplier_products: { supplier_sku: item[:sku] })
        next unless order_item

        order_item.mark_failed!(item[:message])

        # Update supplier_product in_stock to false so future orders
        # won't include items that the platform says are unavailable
        sp = order_item.supplier_product
        if sp&.in_stock
          sp.update!(in_stock: false)
          Rails.logger.info "[OrderPlacement] Marked #{sp.supplier_name} (#{sp.supplier_sku}) as out of stock"
        end
      end

      Rails.logger.warn "[OrderPlacement] Order #{order.id} failed: items unavailable"

      {
        success: false,
        error_type: 'items_unavailable',
        error: error.message,
        details: { unavailable_items: error.items }
      }
    end

    def handle_price_changed_error(error, accept_changes)
      if accept_changes
        # User accepted price changes, update order and retry
        update_order_with_new_prices(error.changes)
        return place_order(accept_price_changes: true)
      end

      order.update!(
        status: 'pending_review',
        error_message: "Prices changed for #{error.changes.count} item(s). Review required."
      )

      Rails.logger.info "[OrderPlacement] Order #{order.id} pending review: price changes"

      {
        success: false,
        error_type: 'price_changed',
        error: error.message,
        details: { price_changes: error.changes },
        requires_review: true
      }
    end

    def handle_account_hold_error(error)
      # Update credential status
      credential = order.user.supplier_credentials.find_by(supplier: order.supplier)
      credential&.mark_on_hold!(error.message)

      order.update!(
        status: 'failed',
        error_message: "Account issue: #{error.message}"
      )

      Rails.logger.error "[OrderPlacement] Order #{order.id} failed: account hold"

      {
        success: false,
        error_type: 'account_hold',
        error: error.message,
        requires_manual_resolution: true
      }
    end

    def handle_captcha_error(error)
      order.update!(
        status: 'pending_manual',
        error_message: 'CAPTCHA detected. Manual order placement required.'
      )

      Rails.logger.warn "[OrderPlacement] Order #{order.id} requires manual intervention: CAPTCHA"

      {
        success: false,
        error_type: 'captcha',
        error: error.message,
        requires_manual_intervention: true,
        supplier_url: order.supplier.base_url
      }
    end

    def handle_delivery_error(error)
      order.update!(
        status: 'failed',
        error_message: error.message
      )

      Rails.logger.warn "[OrderPlacement] Order #{order.id} failed: delivery unavailable"

      {
        success: false,
        error_type: 'delivery_unavailable',
        error: error.message
      }
    end

    def handle_2fa_required(error)
      order.update!(
        status: 'pending_manual',
        error_message: 'Two-factor authentication required. Please enter the verification code.'
      )

      Rails.logger.info "[OrderPlacement] Order #{order.id} waiting for 2FA"

      {
        success: false,
        error_type: '2fa_required',
        error: error.message,
        request_id: error.request_id,
        session_token: error.session_token,
        two_fa_type: error.two_fa_type,
        prompt_message: error.prompt_message
      }
    end

    def handle_generic_error(error)
      Rails.logger.error "[OrderPlacement] Order #{order.id} failed: #{error.class} - #{error.message}"
      Rails.logger.error error.backtrace.first(10).join("\n")

      order.update!(
        status: 'failed',
        error_message: "Order failed: #{error.message}"
      )

      {
        success: false,
        error_type: 'unknown',
        error: error.message
      }
    end

    def update_order_with_new_prices(changes)
      changes.each do |change|
        item = order.order_items.joins(:supplier_product)
                    .find_by(supplier_products: { supplier_sku: change[:sku] })

        next unless item

        item.update!(
          unit_price: change[:new_price],
          line_total: change[:new_price] * item.quantity
        )
      end

      order.recalculate_totals!
    end

    # When scraper.add_to_cart skips items (e.g., unavailable on supplier site),
    # remove those order_items so totals are accurate and checkout matches the cart.
    # Also update supplier_product stock status for future orders.
    def handle_skipped_cart_items(failed_items)
      skipped_names = []

      failed_items.each do |fi|
        order_item = order.order_items.joins(:supplier_product)
                          .find_by(supplier_products: { supplier_sku: fi[:sku] })
        next unless order_item

        # Update supplier_product stock status so future orders know
        sp = order_item.supplier_product
        if sp&.in_stock
          sp.update!(in_stock: false)
          Rails.logger.info "[OrderPlacement] Marked #{sp.supplier_name} (#{sp.supplier_sku}) as out of stock"
        end

        skipped_names << (fi[:name] || sp&.supplier_name)
        order_item.destroy!
      end

      if skipped_names.any?
        order.order_items.reload
        order.recalculate_totals! if order.respond_to?(:recalculate_totals!)

        note = "[Auto-removed] #{skipped_names.size} item(s) unavailable on supplier site: #{skipped_names.join(', ')}"
        order.update!(notes: [order.notes, note].compact.join("\n\n"))

        # Create a structured validation record so the UI can display
        # a prominent alert about removed items.
        # Note: order_items were already destroyed above, so look up
        # supplier_product directly by SKU for the name.
        removed_details = failed_items.map do |fi|
          sp = SupplierProduct.find_by(
            supplier: order.supplier,
            supplier_sku: fi[:sku]
          )
          {
            sku: fi[:sku],
            name: sp&.supplier_name || fi[:name] || "SKU #{fi[:sku]}",
            reason: fi[:error] || 'Out of stock on supplier site'
          }
        end

        OrderValidation.create!(
          order: order,
          validation_type: 'items_removed',
          passed: true, # warning, not blocking
          message: "#{skipped_names.size} item(s) were removed because they are unavailable on #{order.supplier.name}: #{skipped_names.join(', ')}",
          details: { removed_items: removed_details },
          validated_at: Time.current
        )

        Rails.logger.info "[OrderPlacement] Order #{order.id}: #{note}"
      end
    end

    # After OOS items are removed (by validation or add_to_cart), re-check
    # that the remaining total still meets the supplier's order minimum.
    def recheck_order_minimum_after_removals!
      minimum = order.supplier.order_minimum
      return unless minimum

      current_total = order.calculated_subtotal
      return if current_total >= minimum

      difference = minimum - current_total
      raise Scrapers::BaseScraper::OrderMinimumError.new(
        "Order fell below minimum after removing unavailable items. " \
        "Minimum: #{format_currency(minimum)}, Current: #{format_currency(current_total)}.",
        minimum: minimum,
        current_total: current_total
      )
    end

    def format_currency(amount)
      "$#{'%.2f' % amount}"
    end
  end
end
