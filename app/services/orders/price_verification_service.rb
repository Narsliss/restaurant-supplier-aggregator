# frozen_string_literal: true

module Orders
  # Verifies current supplier prices for order items before submission.
  # Opens one browser session per supplier, looks up each item's current price,
  # and compares against the order's expected prices.
  #
  # SAFETY: This service NEVER submits orders or calls any placement code.
  # It only reads prices and updates verification fields.
  class PriceVerificationService
    attr_reader :order, :results

    def initialize(order)
      @order = order
      @results = []
    end

    # Prices updated within this window are considered fresh — skip live verification.
    FRESH_PRICE_THRESHOLD = 1.hour

    # Verify all items in the order against live supplier prices.
    # Returns a result hash with verification outcome.
    def verify!
      Rails.logger.info "[PriceVerification] Starting verification for Order ##{order.id} (#{order.supplier.name})"

      # Fast path: if all item prices were imported recently, skip the browser entirely
      if prices_fresh?
        return skip_with_cached_prices!
      end

      credential = find_credential
      unless credential
        # 2FA suppliers can't re-login without user interaction — auto-skip with cached prices
        if order.supplier.no_password_required?
          return skip_verification!("#{order.supplier.name} requires re-login. Using last imported prices.")
        end
        return fail_verification!("No saved login found for #{order.supplier.name}. Please add your credentials in Supplier Settings.")
      end

      scraper = order.supplier.scraper_klass.new(credential)

      # 2FA suppliers with expired local session: try soft_refresh to check
      # if the supplier-side session is actually still alive before giving up.
      if order.supplier.no_password_required? && !credential.session_valid?
        Rails.logger.info "[PriceVerification] #{order.supplier.name} local session expired, trying soft refresh..."
        if scraper.soft_refresh
          Rails.logger.info "[PriceVerification] #{order.supplier.name} session is still alive!"
          credential.reload # pick up refreshed last_login_at
        else
          return skip_verification!("#{order.supplier.name} session expired. Using last imported prices.")
        end
      end
      skus = order.order_items.includes(:supplier_product).map { |item| item.supplier_product.supplier_sku }.compact

      if skus.empty?
        return fail_verification!("No products to verify for this order.")
      end

      verified_prices = fetch_prices(scraper, skus)
      compare_prices(verified_prices)

      build_result
    rescue Scrapers::BaseScraper::AuthenticationError => e
      Rails.logger.error "[PriceVerification] Auth error for #{order.supplier.name}: #{e.message}"
      if order.supplier.no_password_required?
        skip_verification!("Could not connect to #{order.supplier.name}. Using last imported prices.")
      else
        fail_verification!("Could not log in to #{order.supplier.name}. Please check your credentials in Supplier Settings.")
      end
    rescue Scrapers::BaseScraper::SessionExpiredError => e
      Rails.logger.error "[PriceVerification] Session expired for #{order.supplier.name}: #{e.message}"
      if order.supplier.no_password_required?
        skip_verification!("#{order.supplier.name} session expired. Using last imported prices.")
      else
        fail_verification!("Connection to #{order.supplier.name} expired. Please retry.")
      end
    rescue Scrapers::BaseScraper::CaptchaDetectedError => e
      skip_verification!("#{order.supplier.name} requires manual verification. Using last imported prices.")
    rescue Scrapers::BaseScraper::MaintenanceError => e
      skip_verification!("#{order.supplier.name} is under maintenance. Using last imported prices.")
    rescue Scrapers::BaseScraper::RateLimitedError => e
      fail_verification!("#{order.supplier.name} is busy. Please retry in a few minutes.")
    rescue Ferrum::TimeoutError, Ferrum::ProcessTimeoutError => e
      fail_verification!("#{order.supplier.name} took too long to respond. Please retry.")
    rescue NotImplementedError
      skip_verification!
    rescue => e
      Rails.logger.error "[PriceVerification] Unexpected error: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      fail_verification!("Could not verify prices for #{order.supplier.name}. Please retry or skip.")
    end

    private

    def find_credential
      # Find credential for this supplier belonging to the order's user.
      # For password-based suppliers, we also accept "failed" credentials since
      # the scraper can re-authenticate with the stored password.
      # For 2FA suppliers, only "active" credentials work (can't auto-login).
      statuses = ["active"]
      statuses << "failed" if order.supplier.password_auth?

      order.user.supplier_credentials
        .where(supplier: order.supplier)
        .where(status: statuses)
        .order(Arel.sql("CASE status WHEN 'active' THEN 0 ELSE 1 END"))
        .first
    end

    def fetch_prices(scraper, skus)
      prices = {}

      # Each scraper's scrape_prices opens its own browser session via with_browser,
      # handles login/session restore, and closes the browser when done.
      # We must NOT wrap in an outer with_browser — that causes nested browsers.
      results = scraper.scrape_prices(skus)
      results.each do |result|
        prices[result[:supplier_sku]] = {
          price: result[:current_price],
          in_stock: result[:in_stock] != false,
          name: result[:supplier_name]
        }
      end

      prices
    end

    def compare_prices(verified_prices)
      order.order_items.includes(:supplier_product).each do |item|
        sku = item.supplier_product.supplier_sku
        verified = verified_prices[sku]

        if verified && verified[:price]
          item.update!(verified_price: verified[:price])

          # Also update the supplier product's cached price
          if verified[:price] != item.supplier_product.current_price
            item.supplier_product.update_price!(verified[:price], in_stock: verified[:in_stock])
          end

          @results << {
            item_id: item.id,
            sku: sku,
            name: item.supplier_product.supplier_name,
            expected_price: item.unit_price,
            verified_price: verified[:price],
            difference: verified[:price] - item.unit_price,
            in_stock: verified[:in_stock]
          }
        else
          # Could not verify this item — keep existing price
          @results << {
            item_id: item.id,
            sku: sku,
            name: item.supplier_product.supplier_name,
            expected_price: item.unit_price,
            verified_price: nil,
            difference: 0,
            in_stock: true,
            unverified: true
          }
        end
      end
    end

    def build_result
      verified_total = order.order_items.reload.sum do |item|
        price = item.verified_price || item.unit_price
        price * item.quantity
      end

      total_change = verified_total - (order.subtotal || 0)
      has_changes = @results.any? { |r| r[:difference] != 0 && !r[:unverified] }

      if has_changes && !within_threshold?(total_change)
        order.mark_price_changed!(
          verified_total: verified_total,
          price_change_amount: total_change
        )
        Rails.logger.info "[PriceVerification] Order ##{order.id}: Price changes detected. " \
                          "Old total: $#{order.subtotal}, New total: $#{verified_total}, " \
                          "Change: $#{total_change.round(2)}"
      else
        order.mark_verified!(verified_total: verified_total)
        Rails.logger.info "[PriceVerification] Order ##{order.id}: Prices verified. Total: $#{verified_total}"
      end

      {
        success: true,
        order_id: order.id,
        verified_total: verified_total,
        price_change_amount: total_change.round(2),
        has_price_changes: has_changes && !within_threshold?(total_change),
        results: @results,
        verification_status: order.reload.verification_status
      }
    end

    def within_threshold?(total_change)
      return true if order.subtotal.nil? || order.subtotal == 0
      (total_change.abs / order.subtotal) <= Order::PRICE_CHANGE_THRESHOLD
    end

    def fail_verification!(message)
      Rails.logger.error "[PriceVerification] Order ##{order.id}: #{message}"
      order.mark_verification_failed!(message)

      {
        success: false,
        order_id: order.id,
        error: message,
        verification_status: "failed"
      }
    end

    def skip_verification!(reason = nil)
      reason ||= "Price verification not available for #{order.supplier.name}."
      last_update = latest_price_update
      if last_update
        reason = "#{reason} (prices updated #{time_ago_in_words(last_update)})"
      end

      Rails.logger.info "[PriceVerification] Order ##{order.id}: Skipping — #{reason}"
      order.skip_verification!(reason)

      {
        success: true,
        order_id: order.id,
        skipped: true,
        skip_reason: reason,
        verification_status: "skipped"
      }
    end

    def prices_fresh?
      oldest_price = order.order_items
        .joins(:supplier_product)
        .minimum("supplier_products.price_updated_at")

      oldest_price.present? && oldest_price > FRESH_PRICE_THRESHOLD.ago
    end

    def skip_with_cached_prices!
      last_update = latest_price_update
      ago = last_update ? time_ago_in_words(last_update) : "recently"

      Rails.logger.info "[PriceVerification] Order ##{order.id}: All prices fresh (updated #{ago}). Skipping live verification."

      # Use cached prices as verified prices
      verified_total = order.order_items.includes(:supplier_product).sum do |item|
        item.update!(verified_price: item.unit_price)
        item.unit_price * item.quantity
      end

      order.mark_verified!(verified_total: verified_total)

      {
        success: true,
        order_id: order.id,
        verified_total: verified_total,
        price_change_amount: 0,
        has_price_changes: false,
        results: [],
        verification_status: "verified"
      }
    end

    def latest_price_update
      order.order_items
        .joins(:supplier_product)
        .maximum("supplier_products.price_updated_at")
    end

    def time_ago_in_words(time)
      seconds = (Time.current - time).to_i
      case seconds
      when 0..59 then "just now"
      when 60..3599 then "#{seconds / 60} minutes ago"
      when 3600..86399 then "#{seconds / 3600} hours ago"
      else "#{seconds / 86400} days ago"
      end
    end
  end
end
