module Stripe
  class SeatSyncService
    # Syncs the organization's seat count to their Stripe subscription.
    # Called automatically when members are added or removed.
    #
    # How it works:
    #   - Base plan ($99/mo) includes 5 seats (excludes owner)
    #   - Each seat beyond 5 costs $10/mo
    #   - When seat count changes, we update (or add/remove) the seat line item
    #   - Stripe handles proration automatically
    #
    # Usage:
    #   Stripe::SeatSyncService.call(organization)

    def self.call(organization)
      new(organization).sync
    end

    def initialize(organization)
      @org = organization
      @config = Rails.application.config.stripe_config
    end

    def sync
      return unless should_sync?

      paid_seats = calculate_paid_seats
      seat_item = find_seat_subscription_item

      if paid_seats > 0
        if seat_item
          ::Stripe::SubscriptionItem.update(seat_item.id, quantity: paid_seats)
          Rails.logger.info "[SeatSync] Updated #{@org.name} to #{paid_seats} paid seat(s)"
        else
          ::Stripe::SubscriptionItem.create(
            subscription: stripe_subscription.id,
            price: @config[:seat_price_id],
            quantity: paid_seats
          )
          Rails.logger.info "[SeatSync] Added #{paid_seats} paid seat(s) for #{@org.name}"
        end
      elsif seat_item
        ::Stripe::SubscriptionItem.delete(seat_item.id)
        Rails.logger.info "[SeatSync] Removed paid seats for #{@org.name}"
      end

      @org.update_columns(additional_seats: [paid_seats, 0].max)
    rescue ::Stripe::StripeError => e
      # Don't raise — that would roll back the membership transaction that
      # triggered this sync. But silence is also unacceptable: a failed sync
      # means we're under-charging the org. Log loudly and notify super admin
      # so it can be reconciled manually.
      Rails.logger.error(
        "[SeatSync][REVENUE-LEAK] Stripe error for #{@org.name} (id=#{@org.id}): #{e.message}"
      )
      notify_super_admin_of_failure(e)
    end

    private

    def should_sync?
      return false unless @config[:seat_price_id].present?
      return false unless @org.subscribed? && !@org.complimentary?

      subscription = @org.current_subscription
      return false unless subscription&.stripe_subscription_id.present?

      true
    end

    def calculate_paid_seats
      included = @config[:included_seats] || 5
      [@org.seat_count - included, 0].max
    end

    def stripe_subscription
      @stripe_subscription ||= ::Stripe::Subscription.retrieve(
        @org.current_subscription.stripe_subscription_id
      )
    end

    def find_seat_subscription_item
      stripe_subscription.items.data.find do |item|
        item.price.id == @config[:seat_price_id]
      end
    end

    def notify_super_admin_of_failure(error)
      admin = User.super_admin
      return unless admin&.email

      BillingMailer.seat_sync_failed(@org, error.message).deliver_later
    rescue StandardError => mailer_error
      Rails.logger.error "[SeatSync] Failed to notify admin: #{mailer_error.message}"
    end
  end
end
