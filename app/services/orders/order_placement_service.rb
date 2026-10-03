module Orders
  class OrderPlacementService
    attr_reader :order, :scraper, :validation_result

    def initialize(order)
      @order = order
    end

    def place_order(accept_price_changes: false, skip_warnings: false, skip_pre_validation: false)
      @accept_price_changes = accept_price_changes

      # Email suppliers: route to email-based order placement (no scraper needed)
      if order.supplier.email_supplier?
        return Orders::EmailOrderPlacementService.new(order).place_order
      end

      # Step 1: Run pre-submission validations
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
        # Owners whose one login orders for several restaurants: point the
        # supplier login at THIS order's restaurant and confirm it before any
        # cart is touched (a mismatch raises and fails the order untouched).
        # No-op for every connection without restaurant matches.
        @restaurant_switch = Suppliers::RestaurantSwitcher.new(credential, scraper)
        @restaurant_switch.enter(order.location_id)

        # Step 4: Clear any existing cart items, then add our items
        scraper.clear_cart if scraper.respond_to?(:clear_cart)
        cart_items = build_cart_items
        cart_result = scraper.add_to_cart(cart_items, delivery_date: order.delivery_date)

        # Any item the supplier couldn't take stops the WHOLE order (Carmin,
        # Oct 3 2026, order #386). We used to delete those lines and place the
        # rest, so chefs got short orders with only a yellow banner afterwards
        # (9 CW items across 6 orders). Now nothing is submitted; the chef is
        # told which item and why, and fixes it in the app.
        if cart_result.is_a?(Hash) && cart_result[:failed]&.any?
          raise_for_items_not_added!(cart_result[:failed])
        end

        # Re-check: if item removal dropped us below the order minimum, fail early
        recheck_order_minimum_after_removals!

        # Safety gate: never submit a supplier cart that doesn't match this order.
        # Catches orphaned lines left in the supplier's server-side cart by a
        # prior failed attempt (and anything the chef removed). Supplier-specific
        # — only scrapers that expose cart contents implement it. Fails CLOSED.
        if scraper.respond_to?(:verify_cart_matches!)
          scraper.verify_cart_matches!(build_cart_items)
        end

        # Step 5: Attempt checkout
        # Production always places real orders; development always dry-runs.
        # The per-supplier checkout_enabled flag is only checked in production
        # as an additional per-supplier kill switch.
        dry_run = if Rails.env.production?
                    !order.supplier.checkout_enabled?
                  else
                    true # Always dry-run in development/test
                  end
        result = scraper.checkout(dry_run: dry_run)

        # Step 6: Record result
        # Resolve delivery date: prefer the confirmed date from the supplier
        # (parsed to a real Date), but fall back to the user's original date.
        confirmed_delivery = resolve_delivery_date(result[:delivery_date], order.delivery_date)

        if result[:dry_run]
          order.update!(
            status: 'dry_run_complete',
            confirmation_number: result[:confirmation_number],
            total_amount: result[:total].to_f > 0 ? result[:total].to_f : order.calculated_subtotal,
            submitted_at: Time.current,
            delivery_date: confirmed_delivery,
            notes: [order.notes, dry_run_summary(result)].compact.join("\n\n")
          )
          order.order_items.update_all(status: 'pending')

          Rails.logger.info "[OrderPlacement] Order #{order.id} DRY RUN complete for #{order.supplier.name}"

          { success: true, order: order.reload, dry_run: true }
        else
          # Prefer supplier-reported total (source of truth), fall back to our
          # calculated subtotal only if the supplier didn't return one.
          # Note: can't use .presence here — 0.0.presence returns 0.0 (not nil),
          # so a nil-to-float conversion (nil.to_f = 0.0) would override the fallback.
          best_total = result[:total].to_f > 0 ? result[:total].to_f : order.calculated_subtotal

          order.update!(
            status: 'submitted',
            confirmation_number: result[:confirmation_number],
            total_amount: best_total,
            submitted_at: Time.current,
            delivery_date: confirmed_delivery
          )
          order.order_items.update_all(status: 'added')

          # US Foods finalizes exceptions (out of stock, subs, short-fills) shortly
          # after submit. Kick off a fast re-check so the chef is alerted within
          # ~a minute, while they're still in the app. Isolated in its own rescue:
          # the order is already submitted, so a failure to enqueue must NOT bubble
          # into the generic rescue below (which would wrongly mark it failed).
          if order.supplier.code == 'usfoods'
            begin
              CheckOrderExceptionsJob.set(wait: 20.seconds).perform_later(order.id)
            rescue StandardError => e
              Rails.logger.warn "[OrderPlacement] Order #{order.id} submitted, but scheduling the exception check failed: #{e.message}"
            end
          end

          Rails.logger.info "[OrderPlacement] Order #{order.id} submitted: #{result[:confirmation_number]}"

          { success: true, order: order.reload }
        end
      rescue Scrapers::BaseScraper::OrderMinimumError => e
        handle_order_minimum_error(e)
      rescue Scrapers::BaseScraper::ItemUnavailableError => e
        handle_item_unavailable_error(e)
      rescue Scrapers::BaseScraper::CartMismatchError => e
        handle_cart_mismatch_error(e)
      # Defensive: no scraper currently raises PriceChangedError at submit time
      # (price drift is caught earlier by verification). Kept so a scraper that
      # detects an at-checkout price change routes to review instead of failing.
      rescue Scrapers::BaseScraper::PriceChangedError => e
        handle_price_changed_error(e, accept_price_changes)
      rescue Scrapers::BaseScraper::AccountHoldError => e
        handle_account_hold_error(e, credential)
      rescue Scrapers::BaseScraper::CaptchaDetectedError => e
        handle_captcha_error(e)
      rescue Scrapers::BaseScraper::DeliveryUnavailableError => e
        handle_delivery_error(e)
      rescue Scrapers::BaseScraper::OrderUnconfirmedError => e
        handle_unconfirmed_submit(e)
      rescue Authentication::TwoFactorHandler::TwoFactorRequired => e
        handle_2fa_required(e)
      rescue StandardError => e
        handle_generic_error(e)
      ensure
        # Close persistent order browser if scraper uses one (PPO, US Foods, WCW).
        # Idempotent — safe even if checkout already closed it.
        scraper&.close_order_browser! if scraper&.respond_to?(:close_order_browser!)
        # Multi-restaurant logins: back to the connection's home restaurant.
        @restaurant_switch&.leave
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
          item = item.symbolize_keys if item.respond_to?(:symbolize_keys)
          lines << "  - #{item[:name]} (#{item[:sku]}): qty #{item[:quantity]} @ $#{item[:price]}"
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
      order.order_items.includes(supplier_product: :product).each do |order_item|
        product = order_item.supplier_product&.product
        next unless product

        order_list.order_list_items.build(
          product: product,
          quantity: order_item.quantity
        )
      end

      # Run pre-order validation
      validator = PreOrderValidationService.new(
        order_list: order_list,
        supplier: order.supplier,
        user: order.user,
        delivery_date: order.delivery_date,
        location_id: order.location_id
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
      # Same query as always, except an owner with matched restaurants only
      # gets a connection that serves this order's restaurant.
      credential = Suppliers::OrderCredential.scope(order, statuses: %w[active]).take

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
          expected_price: item.unit_price,
          uom: item.uom
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
      lines = error.items.map do |i|
        reason = i[:message].presence || i[:error].presence
        [i[:name].presence || "SKU #{i[:sku]}", reason].compact.join(' — ')
      end
      count = error.items.count

      order.update!(
        status: 'failed',
        error_message: "Not placed. #{order.supplier.name} couldn't take #{count} item#{'s' if count != 1}: " \
                       "#{lines.join('; ')}. Remove or change #{count == 1 ? 'it' : 'them'} and resubmit."
      )

      # Mark specific items as failed and update supplier product stock status
      error.items.each do |item|
        order_item = order.order_items.joins(:supplier_product)
                          .find_by(supplier_products: { supplier_sku: item[:sku] })
        next unless order_item

        order_item.mark_failed!(item[:message])

        # Only mark supplier_product as out-of-stock when the error indicates a genuine
        # stock issue (supplier site says "out of stock", "discontinued", etc.).
        # Browser/rendering errors (e.g., "Element is not focusable", "no native input")
        # should NOT poison the database — they're transient infrastructure issues.
        sp = order_item.supplier_product
        error_msg = item[:error] || item[:message] || ''
        if sp&.in_stock && stock_related_error?(error_msg)
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

    def handle_cart_mismatch_error(error)
      order.update!(
        status: 'pending_review',
        error_message: 'Supplier cart did not match your order, so we did not submit it. ' \
                       'This usually means a leftover item from a previous attempt. ' \
                       'Please review and try again.'
      )

      Rails.logger.error "[OrderPlacement] Order #{order.id} HALTED (cart mismatch): #{error.discrepancies.inspect}"

      {
        success: false,
        error_type: 'cart_mismatch',
        error: error.message,
        details: { discrepancies: error.discrepancies },
        requires_review: true
      }
    end

    # +credential+: the login that placed this order. With a login per
    # restaurant (Performance), that's the one to flag — never "any" login for
    # the supplier, which could put another restaurant's login on hold.
    def handle_account_hold_error(error, credential)
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

    # The supplier may have the order. pending_manual is not retryable, so the
    # chef can't accidentally place it twice — they check the supplier first.
    def handle_unconfirmed_submit(error)
      order.update!(status: 'pending_manual', error_message: error.message)

      Rails.logger.error "[OrderPlacement] Order #{order.id} UNCONFIRMED at #{order.supplier.name}: #{error.message}"

      {
        success: false,
        error_type: 'unconfirmed',
        error: error.message,
        requires_manual_intervention: true
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

    # add_to_cart reported items it couldn't put in the supplier cart. Stop the
    # whole order (handled by handle_item_unavailable_error): never delete the
    # lines and place the rest. Failed entries carry the reason under :error
    # (most scrapers) or :reason (Performance).
    def raise_for_items_not_added!(failed_items)
      items = failed_items.map do |fi|
        sp = order.order_items.joins(:supplier_product)
                  .find_by(supplier_products: { supplier_sku: fi[:sku] })&.supplier_product
        {
          sku: fi[:sku],
          name: fi[:name].presence || sp&.supplier_name || "SKU #{fi[:sku]}",
          message: fi[:error].presence || fi[:reason].presence || fi[:message].presence || 'could not be added to the cart'
        }
      end

      raise Scrapers::BaseScraper::ItemUnavailableError.new(
        "#{order.supplier.name} could not add #{items.size} item(s) to the cart",
        items: items
      )
    end

    # After OOS items are removed by validation, re-check
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

    # Returns true when the error message indicates a genuine stock/availability issue
    # from the supplier site (e.g., "out of stock", "discontinued"). Returns false for
    # browser/rendering errors (e.g., "Element is not focusable", "no native input").
    def stock_related_error?(error_message)
      # No reason given is NOT evidence of a stock problem: Performance's failed
      # entries had no :error, so every transient failure marked items out of
      # stock and future orders silently removed them.
      return false if error_message.blank?
      error_message.match?(/out of stock|unavailable|discontinued|no longer available|not available|removed from catalog/i)
    end

    # Parse the supplier-confirmed delivery date string (e.g., "Mar 16")
    # into a real Date. Falls back to the user's original delivery_date
    # if the scraper string is nil, blank, or unparseable.
    def resolve_delivery_date(scraper_date_str, original_date)
      return original_date if scraper_date_str.blank?

      # Already a Date/Time object? Use it directly.
      return scraper_date_str.to_date if scraper_date_str.respond_to?(:to_date) && !scraper_date_str.is_a?(String)

      # Try parsing partial strings like "Mar 16" by assuming the current year
      # (or next year if the month has already passed).
      parsed = begin
        date = Date.parse(scraper_date_str)
        # Date.parse("Mar 16") gives 2026-03-16 — but if the month/day
        # is ambiguous and year isn't included, it defaults to current year.
        date
      rescue ArgumentError, TypeError
        nil
      end

      if parsed
        Rails.logger.info "[OrderPlacement] Resolved delivery date: '#{scraper_date_str}' → #{parsed}"
        parsed
      else
        Rails.logger.warn "[OrderPlacement] Could not parse delivery date '#{scraper_date_str}', keeping original: #{original_date}"
        original_date
      end
    end
  end
end
