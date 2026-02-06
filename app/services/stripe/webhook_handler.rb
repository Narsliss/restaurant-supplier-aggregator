module Stripe
  class WebhookHandler
    class << self
      def handle(event)
        # Check idempotency
        return { status: :already_processed } if BillingEvent.already_processed?(event.id)

        handler = new(event)
        handler.process
      end
    end

    def initialize(event)
      @event = event
    end

    def process
      Rails.logger.info "[Stripe Webhook] Processing #{@event.type} (#{@event.id})"

      result = case @event.type
               # Checkout events
               when "checkout.session.completed"
                 handle_checkout_completed
               # Subscription events
               when "customer.subscription.created"
                 handle_subscription_created
               when "customer.subscription.updated"
                 handle_subscription_updated
               when "customer.subscription.deleted"
                 handle_subscription_deleted
               when "customer.subscription.trial_will_end"
                 handle_trial_will_end
               # Invoice events
               when "invoice.paid"
                 handle_invoice_paid
               when "invoice.payment_failed"
                 handle_invoice_payment_failed
               when "invoice.created"
                 handle_invoice_created
               when "invoice.finalized"
                 handle_invoice_finalized
               # Customer events
               when "customer.created"
                 handle_customer_created
               when "customer.updated"
                 handle_customer_updated
               else
                 Rails.logger.info "[Stripe Webhook] Unhandled event type: #{@event.type}"
                 { status: :ignored }
               end

      result
    rescue StandardError => e
      Rails.logger.error "[Stripe Webhook] Error processing #{@event.type}: #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n")
      { status: :error, message: e.message }
    end

    private

    def handle_checkout_completed
      session = @event.data.object
      return { status: :ignored } unless session.mode == "subscription"

      user = find_user_from_metadata(session.metadata) ||
             User.find_by(stripe_customer_id: session.customer)

      return { status: :user_not_found } unless user

      # Update user's Stripe customer ID if needed
      user.update!(stripe_customer_id: session.customer) unless user.stripe_customer_id

      # Fetch and sync the subscription
      if session.subscription
        stripe_subscription = ::Stripe::Subscription.retrieve(session.subscription)
        Subscription.sync_from_stripe(stripe_subscription, user: user)
      end

      record_event(user: user)
      { status: :success }
    end

    def handle_subscription_created
      stripe_subscription = @event.data.object
      user = find_user_for_subscription(stripe_subscription)
      return { status: :user_not_found } unless user

      subscription = Subscription.sync_from_stripe(stripe_subscription, user: user)
      record_event(user: user, subscription: subscription)

      { status: :success }
    end

    def handle_subscription_updated
      stripe_subscription = @event.data.object
      subscription = Subscription.find_by(stripe_subscription_id: stripe_subscription.id)

      if subscription
        subscription = Subscription.sync_from_stripe(stripe_subscription, user: subscription.user)
        record_event(user: subscription.user, subscription: subscription)
        { status: :success }
      else
        # Try to create if it doesn't exist
        user = find_user_for_subscription(stripe_subscription)
        if user
          subscription = Subscription.sync_from_stripe(stripe_subscription, user: user)
          record_event(user: user, subscription: subscription)
          { status: :success }
        else
          { status: :subscription_not_found }
        end
      end
    end

    def handle_subscription_deleted
      stripe_subscription = @event.data.object
      subscription = Subscription.find_by(stripe_subscription_id: stripe_subscription.id)

      if subscription
        subscription.update!(
          status: "canceled",
          canceled_at: Time.current,
          ended_at: stripe_subscription.ended_at ? Time.zone.at(stripe_subscription.ended_at) : Time.current
        )
        record_event(user: subscription.user, subscription: subscription)
        { status: :success }
      else
        { status: :subscription_not_found }
      end
    end

    def handle_trial_will_end
      stripe_subscription = @event.data.object
      subscription = Subscription.find_by(stripe_subscription_id: stripe_subscription.id)

      if subscription
        # Could send email notification here
        Rails.logger.info "[Stripe] Trial ending soon for user #{subscription.user_id}"
        record_event(user: subscription.user, subscription: subscription)
        { status: :success }
      else
        { status: :subscription_not_found }
      end
    end

    def handle_invoice_paid
      stripe_invoice = @event.data.object
      invoice = Invoice.sync_from_stripe(stripe_invoice)
      record_event(user: invoice.user, subscription: invoice.subscription)
      { status: :success }
    end

    def handle_invoice_payment_failed
      stripe_invoice = @event.data.object
      invoice = Invoice.sync_from_stripe(stripe_invoice)

      # Could send email notification about failed payment
      Rails.logger.warn "[Stripe] Payment failed for user #{invoice.user_id}"

      record_event(user: invoice.user, subscription: invoice.subscription)
      { status: :success }
    end

    def handle_invoice_created
      stripe_invoice = @event.data.object
      Invoice.sync_from_stripe(stripe_invoice)
      { status: :success }
    end

    def handle_invoice_finalized
      stripe_invoice = @event.data.object
      Invoice.sync_from_stripe(stripe_invoice)
      { status: :success }
    end

    def handle_customer_created
      customer = @event.data.object
      user = find_user_from_metadata(customer.metadata) ||
             User.find_by(email: customer.email)

      if user && user.stripe_customer_id.blank?
        user.update!(stripe_customer_id: customer.id)
        record_event(user: user)
      end

      { status: :success }
    end

    def handle_customer_updated
      # Usually nothing to do here
      { status: :success }
    end

    def find_user_for_subscription(stripe_subscription)
      # Try metadata first
      user = find_user_from_metadata(stripe_subscription.metadata)
      return user if user

      # Try customer ID
      User.find_by(stripe_customer_id: stripe_subscription.customer)
    end

    def find_user_from_metadata(metadata)
      return nil unless metadata&.user_id

      User.find_by(id: metadata.user_id)
    end

    def record_event(user: nil, subscription: nil)
      BillingEvent.record!(@event, user: user, subscription: subscription)
                  .mark_processed!
    end
  end
end
