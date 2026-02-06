module Orders
  class OrderPlacementService
    attr_reader :order, :scraper, :validation_result

    def initialize(order)
      @order = order
    end

    def place_order(accept_price_changes: false, skip_warnings: false)
      # Step 1: Run pre-submission validations
      validate_order!(skip_warnings: skip_warnings)

      # Step 2: Get credentials
      credential = get_active_credential

      # Step 3: Initialize scraper
      @scraper = order.supplier.scraper_klass.new(credential)

      order.update!(status: "processing")

      begin
        # Step 4: Add items to cart with delivery date
        cart_items = build_cart_items
        scraper.add_to_cart(cart_items, delivery_date: order.delivery_date)

        # Step 5: Attempt checkout with error handling
        result = scraper.checkout

        # Step 6: Record success
        order.update!(
          status: "submitted",
          confirmation_number: result[:confirmation_number],
          total_amount: result[:total],
          submitted_at: Time.current,
          delivery_date: result[:delivery_date]
        )

        # Mark all items as added
        order.order_items.update_all(status: "added")

        Rails.logger.info "[OrderPlacement] Order #{order.id} submitted successfully: #{result[:confirmation_number]}"

        { success: true, order: order.reload }

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

      rescue => e
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

    def validate_order!(skip_warnings: false)
      validator = OrderValidationService.new(order)
      @validation_result = validator.validate!

      unless skip_warnings
        if validation_result[:warnings].any?
          warning_messages = validation_result[:warnings].map { |w| w[:message] }.join("; ")
          order.update!(
            status: "pending_review",
            notes: "Warnings: #{warning_messages}"
          )
        end
      end
    end

    def get_active_credential
      credential = order.user.supplier_credentials.find_by(
        supplier: order.supplier,
        status: "active"
      )

      unless credential
        order.update!(status: "failed", error_message: "No active credentials for #{order.supplier.name}")
        raise OrderValidationService::ValidationError.new(
          errors: [{ type: "no_credentials", message: "No active credentials for #{order.supplier.name}" }]
        )
      end

      credential
    end

    def build_cart_items
      order.order_items.includes(:supplier_product).map do |item|
        {
          sku: item.supplier_product.supplier_sku,
          quantity: item.quantity.to_i,
          expected_price: item.unit_price
        }
      end
    end

    def handle_order_minimum_error(error)
      difference = error.minimum - error.current_total

      order.update!(
        status: "failed",
        error_message: "Order minimum not met. Minimum: #{format_currency(error.minimum)}, " \
                       "Current: #{format_currency(error.current_total)}. " \
                       "Add #{format_currency(difference)} more to proceed."
      )

      Rails.logger.warn "[OrderPlacement] Order #{order.id} failed: minimum not met"

      {
        success: false,
        error_type: "order_minimum",
        error: error.message,
        details: {
          minimum: error.minimum,
          current_total: error.current_total,
          difference: difference
        }
      }
    end

    def handle_item_unavailable_error(error)
      item_names = error.items.map { |i| i[:name] }.compact.join(", ")

      order.update!(
        status: "failed",
        error_message: "#{error.items.count} item(s) are unavailable: #{item_names}"
      )

      # Mark specific items as failed
      error.items.each do |item|
        order_item = order.order_items.joins(:supplier_product)
          .find_by(supplier_products: { supplier_sku: item[:sku] })
        order_item&.mark_failed!(item[:message])
      end

      Rails.logger.warn "[OrderPlacement] Order #{order.id} failed: items unavailable"

      {
        success: false,
        error_type: "items_unavailable",
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
        status: "pending_review",
        error_message: "Prices changed for #{error.changes.count} item(s). Review required."
      )

      Rails.logger.info "[OrderPlacement] Order #{order.id} pending review: price changes"

      {
        success: false,
        error_type: "price_changed",
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
        status: "failed",
        error_message: "Account issue: #{error.message}"
      )

      Rails.logger.error "[OrderPlacement] Order #{order.id} failed: account hold"

      {
        success: false,
        error_type: "account_hold",
        error: error.message,
        requires_manual_resolution: true
      }
    end

    def handle_captcha_error(error)
      order.update!(
        status: "pending_manual",
        error_message: "CAPTCHA detected. Manual order placement required."
      )

      Rails.logger.warn "[OrderPlacement] Order #{order.id} requires manual intervention: CAPTCHA"

      {
        success: false,
        error_type: "captcha",
        error: error.message,
        requires_manual_intervention: true,
        supplier_url: order.supplier.base_url
      }
    end

    def handle_delivery_error(error)
      order.update!(
        status: "failed",
        error_message: error.message
      )

      Rails.logger.warn "[OrderPlacement] Order #{order.id} failed: delivery unavailable"

      {
        success: false,
        error_type: "delivery_unavailable",
        error: error.message
      }
    end

    def handle_2fa_required(error)
      order.update!(
        status: "pending_manual",
        error_message: "Two-factor authentication required. Please enter the verification code."
      )

      Rails.logger.info "[OrderPlacement] Order #{order.id} waiting for 2FA"

      {
        success: false,
        error_type: "2fa_required",
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
        status: "failed",
        error_message: "Order failed: #{error.message}"
      )

      {
        success: false,
        error_type: "unknown",
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

    def format_currency(amount)
      "$#{'%.2f' % amount}"
    end
  end
end
