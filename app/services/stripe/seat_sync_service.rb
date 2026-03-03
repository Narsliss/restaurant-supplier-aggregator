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
          # Update existing seat line item quantity
          ::Stripe::SubscriptionItem.update(seat_item.id, quantity: paid_seats)
          Rails.logger.info "[SeatSync] Updated #{@org.name} to #{paid_seats} paid seat(s)"
        else
          # Add seat line item to existing subscription
          ::Stripe::SubscriptionItem.create(
            subscription: stripe_subscription.id,
            price: @config[:seat_price_id],
            quantity: paid_seats
          )
          Rails.logger.info "[SeatSync] Added #{paid_seats} paid seat(s) for #{@org.name}"
        end
      elsif seat_item
        # No paid seats needed — remove the seat line item
        ::Stripe::SubscriptionItem.delete(seat_item.id)
        Rails.logger.info "[SeatSync] Removed paid seats for #{@org.name}"
      end

      # Keep the local additional_seats count in sync
      @org.update_columns(additional_seats: [paid_seats, 0].max)
    rescue ::Stripe::StripeError => e
      Rails.logger.error "[SeatSync] Stripe error for #{@org.name}: #{e.message}"
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
  end
end
