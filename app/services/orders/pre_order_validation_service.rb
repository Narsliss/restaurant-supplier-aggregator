# frozen_string_literal: true

module Orders
  # Performs thorough validation of order items before placement
  # Checks: stock availability, current prices, order minimums, delivery availability
  class PreOrderValidationService
    attr_reader :order_list, :supplier, :user, :validation_errors, :price_changes, :delivery_date

    def initialize(order_list:, supplier:, user:, delivery_date: nil)
      @order_list = order_list
      @supplier = supplier
      @user = user
      @delivery_date = delivery_date || Date.tomorrow
      @validation_errors = []
      @price_changes = []
      @warnings = []
    end

    # Perform full validation before order placement
    # Returns validation result hash
    def validate!
      Rails.logger.info "[PreOrderValidation] Starting validation for #{supplier.name} order"

      # Check 1: User has valid credentials
      validate_credentials!

      # Check 2: Establish scraper connection and validate session
      establish_scraper_connection!

      # Check 3: Validate stock availability for all items
      validate_stock_availability!

      # Check 4: Validate current prices
      validate_prices!

      # Check 5: Validate order minimum
      validate_order_minimum!

      # Check 6: Validate delivery availability
      validate_delivery_availability!

      # Build and return result
      build_result
    rescue StandardError => e
      handle_validation_error(e)
    ensure
      @scraper&.close_browser
    end

    # Quick check - just validates without detailed scraper interaction
    # Uses cached data only (faster but less thorough)
    def quick_validate
      validate_credentials!
      validate_cached_stock!
      validate_cached_prices!

      build_result
    end

    private

    def validate_credentials!
      @credential = user.credential_for(supplier)

      unless @credential
        add_error(:credentials, "No credentials found for #{supplier.name}")
        return
      end

      return if @credential.active?

      add_error(:credentials, "Credentials for #{supplier.name} are not active (status: #{@credential.status})")
    end

    def establish_scraper_connection!
      return if @validation_errors.any?

      @scraper = supplier.scraper_klass.new(@credential)

      # Try soft refresh first to avoid triggering 2FA
      if @scraper.respond_to?(:soft_refresh)
        unless @scraper.soft_refresh
          add_error(:session, "Could not establish connection to #{supplier.name}. Session may have expired.")
        end
      else
        # Fallback: try login (may trigger 2FA)
        begin
          @scraper.login
        rescue Authentication::TwoFactorHandler::TwoFactorRequired
          add_warning(:two_fa_required, '2FA required to validate order. Please complete authentication first.')
        rescue StandardError => e
          add_error(:session, "Failed to connect to #{supplier.name}: #{e.message}")
        end
      end
    end

    def validate_stock_availability!
      return if @validation_errors.any? || !@scraper

      order_items.each do |item|
        product = item.supplier_product
        next unless product

        begin
          # Check real-time stock via scraper
          stock_info = @scraper.check_stock(product.supplier_sku)

          if stock_info[:in_stock] == false
            add_error(:stock, "#{product.supplier_name} is out of stock", item: item)
            item.mark_unavailable!(stock_info[:message] || 'Out of stock')
          elsif stock_info[:available_quantity] && stock_info[:available_quantity] < item.quantity
            add_error(:stock,
                      "#{product.supplier_name} has insufficient stock. Available: #{stock_info[:available_quantity]}, Requested: #{item.quantity}", item: item)
          end
        rescue NotImplementedError
          # Scraper doesn't support stock checking - fall back to cached data
          validate_cached_stock_for_item(item)
        rescue StandardError => e
          Rails.logger.warn "[PreOrderValidation] Stock check failed for #{product.supplier_sku}: #{e.message}"
          # Don't fail validation on stock check error - use cached data
          validate_cached_stock_for_item(item)
        end
      end
    end

    def validate_cached_stock!
      order_items.each do |item|
        validate_cached_stock_for_item(item)
      end
    end

    def validate_cached_stock_for_item(item)
      product = item.supplier_product
      return unless product

      return unless product.out_of_stock?

      add_error(:stock, "#{product.supplier_name} is out of stock (cached data)", item: item)
    end

    def validate_prices!
      return if @validation_errors.any? || !@scraper

      order_items.each do |item|
        product = item.supplier_product
        next unless product

        begin
          # Check real-time price via scraper
          current_info = @scraper.get_product_info(product.supplier_sku)

          if current_info[:price] && current_info[:price] != product.current_price
            # Price has changed
            price_change = {
              item: item,
              product: product,
              old_price: product.current_price,
              new_price: current_info[:price],
              difference: current_info[:price] - product.current_price
            }

            @price_changes << price_change

            # Update the product's price in our database
            product.update_price!(current_info[:price], in_stock: current_info[:in_stock] != false)

            add_warning(:price_changed,
                        "#{product.supplier_name} price changed from $#{price_change[:old_price]} to $#{price_change[:new_price]}", item: item)
          end
        rescue NotImplementedError
          # Scraper doesn't support price checking - skip
          Rails.logger.debug "[PreOrderValidation] Scraper doesn't support price checking for #{supplier.name}"
        rescue StandardError => e
          Rails.logger.warn "[PreOrderValidation] Price check failed for #{product.supplier_sku}: #{e.message}"
          # Don't fail validation on price check error
        end
      end
    end

    def validate_cached_prices!
      # Check if any cached prices are stale (> 1 hour old)
      stale_products = order_items
                       .map(&:supplier_product)
                       .compact
                       .select { |p| p.last_scraped_at.nil? || p.last_scraped_at < 1.hour.ago }

      return unless stale_products.any?

      add_warning(:stale_prices, "Price data for #{stale_products.count} item(s) is stale and may have changed")
    end

    def validate_order_minimum!
      return if @validation_errors.any? || !@scraper

      begin
        minimum_info = @scraper.get_order_minimum

        if minimum_info[:minimum] && order_total < minimum_info[:minimum]
          difference = minimum_info[:minimum] - order_total
          add_error(:order_minimum, "Order minimum is $#{'%.2f' % minimum_info[:minimum]}. " \
                                    "Current total: $#{'%.2f' % order_total}. " \
                                    "Need $#{'%.2f' % difference} more.")
        end
      rescue NotImplementedError
        # Scraper doesn't support order minimum checking - skip
        Rails.logger.debug "[PreOrderValidation] Scraper doesn't support order minimum checking for #{supplier.name}"
      rescue StandardError => e
        Rails.logger.warn "[PreOrderValidation] Order minimum check failed: #{e.message}"
        # Don't fail validation on this error
      end
    end

    def validate_delivery_availability!
      return if @validation_errors.any? || !@scraper

      begin
        delivery_info = @scraper.get_delivery_availability(delivery_date)

        unless delivery_info[:available]
          add_error(:delivery,
                    "Delivery is not available for #{delivery_date.strftime('%A, %B %d')}. #{delivery_info[:message] || 'Please select a different date.'}")
        end

        if delivery_info[:cutoff_time] && Time.current > delivery_info[:cutoff_time]
          add_error(:delivery,
                    "Order cutoff time (#{delivery_info[:cutoff_time].strftime('%I:%M %p')}) has passed for #{delivery_date.strftime('%A, %B %d')}")
        end
      rescue NotImplementedError
        # Scraper doesn't support delivery checking - skip
        Rails.logger.debug "[PreOrderValidation] Scraper doesn't support delivery checking for #{supplier.name}"
      rescue StandardError => e
        Rails.logger.warn "[PreOrderValidation] Delivery check failed: #{e.message}"
        # Don't fail validation on this error
      end
    end

    def build_result
      {
        valid: @validation_errors.empty?,
        errors: @validation_errors,
        warnings: @warnings,
        price_changes: @price_changes.map do |pc|
          {
            item_id: pc[:item].id,
            product_name: pc[:product].supplier_name,
            old_price: pc[:old_price],
            new_price: pc[:new_price],
            difference: pc[:difference]
          }
        end,
        can_proceed: @validation_errors.empty? && @warnings.none? { |w| w[:type] == :two_fa_required },
        requires_2fa: @warnings.any? { |w| w[:type] == :two_fa_required },
        order_total: order_total,
        item_count: order_items.count
      }
    end

    def handle_validation_error(error)
      Rails.logger.error "[PreOrderValidation] Validation failed: #{error.class} - #{error.message}"
      Rails.logger.error error.backtrace.first(5).join("\n")

      add_error(:system, "Validation failed: #{error.message}")

      build_result
    end

    def order_items
      @order_items ||= order_list.order_list_items.includes(:supplier_product)
    end

    def order_total
      order_items.sum { |item| item.supplier_product&.current_price.to_f * item.quantity }
    end

    def add_error(type, message, item: nil)
      error = { type: type, message: message }
      error[:item_id] = item.id if item
      @validation_errors << error
    end

    def add_warning(type, message, item: nil)
      warning = { type: type, message: message }
      warning[:item_id] = item.id if item
      @warnings << warning
    end
  end
end
