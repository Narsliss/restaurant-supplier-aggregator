module Stripe
  class WebhookHandler
    class << self
      # Entry point. Records the event before processing so that:
      #   1. Duplicate deliveries from Stripe (parallel retries) are detected
      #      atomically via the BillingEvent unique constraint.
      #   2. A handler that crashes mid-flight still leaves an audit row,
      #      avoiding infinite Stripe retry loops.
      def handle(event)
        billing_event = upsert_billing_event(event)
        return { status: :already_processed } if billing_event.processed?

        new(event, billing_event: billing_event).process
      end

      private

      def upsert_billing_event(event)
        BillingEvent.create!(
          stripe_event_id: event.id,
          event_type: event.type,
          data: event.data.to_h,
          processed: false
        )
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        # Either the unique DB constraint or the model-level uniqueness
        # validation tripped — both indicate this event was already recorded.
        BillingEvent.find_by!(stripe_event_id: event.id)
      end
    end

    def initialize(event, billing_event:)
      @event = event
      @billing_event = billing_event
    end

    def process
      Rails.logger.info "[Stripe Webhook] Processing #{@event.type} (#{@event.id})"

      result = dispatch
      finalize(result)
      result
    rescue StandardError => e
      Rails.logger.error "[Stripe Webhook] Error processing #{@event.type}: #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n")
      @billing_event.update!(error_message: e.message)
      { status: :error, message: e.message }
    end

    private

    def dispatch
      case @event.type
      # Checkout
      when "checkout.session.completed"
        handle_checkout_completed
      # Subscription lifecycle
      when "customer.subscription.created"
        handle_subscription_created
      when "customer.subscription.updated"
        handle_subscription_updated
      when "customer.subscription.deleted"
        handle_subscription_deleted
      when "customer.subscription.paused"
        handle_subscription_paused
      when "customer.subscription.resumed"
        handle_subscription_resumed
      when "customer.subscription.trial_will_end"
        handle_trial_will_end
      # Invoices
      when "invoice.paid"
        handle_invoice_paid
      when "invoice.payment_failed"
        handle_invoice_payment_failed
      when "invoice.payment_action_required"
        handle_invoice_payment_action_required
      when "invoice.created"
        handle_invoice_created
      when "invoice.finalized"
        handle_invoice_finalized
      # Customer
      when "customer.created"
        handle_customer_created
      when "customer.updated"
        handle_customer_updated
      else
        Rails.logger.info "[Stripe Webhook] Unhandled event type: #{@event.type}"
        { status: :ignored }
      end
    end

    # Records attribution on the BillingEvent and marks it processed on success.
    # Non-success statuses leave processed=false so they remain queryable for
    # debugging (the controller still returns 200, so Stripe won't retry).
    def finalize(result)
      attrs = {}
      attrs[:user_id] = result[:user].id if result[:user]
      attrs[:subscription_id] = result[:subscription].id if result[:subscription]

      if result[:status] == :success
        @billing_event.update!(processed: true, error_message: nil, **attrs)
      elsif attrs.any?
        @billing_event.update!(**attrs)
      end
    end

    def handle_checkout_completed
      session = @event.data.object
      return { status: :ignored } unless session.mode == "subscription"

      org = find_organization_from_metadata(session.metadata) ||
            Organization.find_by(stripe_customer_id: session.customer)
      user = find_user_from_metadata(session.metadata) || org&.owner

      return { status: :user_not_found } unless user

      org ||= user.current_organization
      org&.update!(stripe_customer_id: session.customer) if org && org.stripe_customer_id.blank?

      subscription = nil
      if session.subscription
        stripe_subscription = ::Stripe::Subscription.retrieve(session.subscription)
        subscription = ::Subscription.sync_from_stripe(stripe_subscription, user: user)
      end

      BillingMailer.welcome(subscription).deliver_later if subscription

      { status: :success, user: user, subscription: subscription }
    end

    def handle_subscription_created
      stripe_subscription = @event.data.object
      user = find_user_for_subscription(stripe_subscription)
      return { status: :user_not_found } unless user

      subscription = ::Subscription.sync_from_stripe(stripe_subscription, user: user)

      { status: :success, user: user, subscription: subscription }
    end

    def handle_subscription_updated
      stripe_subscription = @event.data.object
      subscription = ::Subscription.find_by(stripe_subscription_id: stripe_subscription.id)

      if subscription
        subscription = Subscription.sync_from_stripe(stripe_subscription, user: subscription.user)
        return { status: :success, user: subscription.user, subscription: subscription }
      end

      user = find_user_for_subscription(stripe_subscription)
      return { status: :subscription_not_found } unless user

      subscription = ::Subscription.sync_from_stripe(stripe_subscription, user: user)
      { status: :success, user: user, subscription: subscription }
    end

    def handle_subscription_deleted
      stripe_subscription = @event.data.object
      subscription = ::Subscription.find_by(stripe_subscription_id: stripe_subscription.id)
      return { status: :subscription_not_found } unless subscription

      subscription.update!(
        status: "canceled",
        canceled_at: Time.current,
        ended_at: stripe_subscription.ended_at ? Time.zone.at(stripe_subscription.ended_at) : Time.current
      )

      BillingMailer.subscription_canceled(subscription).deliver_later

      { status: :success, user: subscription.user, subscription: subscription }
    end

    def handle_subscription_paused
      stripe_subscription = @event.data.object
      subscription = ::Subscription.find_by(stripe_subscription_id: stripe_subscription.id)
      return { status: :subscription_not_found } unless subscription

      ::Subscription.sync_from_stripe(stripe_subscription, user: subscription.user)
      { status: :success, user: subscription.user, subscription: subscription.reload }
    end

    def handle_subscription_resumed
      stripe_subscription = @event.data.object
      subscription = ::Subscription.find_by(stripe_subscription_id: stripe_subscription.id)
      return { status: :subscription_not_found } unless subscription

      ::Subscription.sync_from_stripe(stripe_subscription, user: subscription.user)
      { status: :success, user: subscription.user, subscription: subscription.reload }
    end

    def handle_trial_will_end
      stripe_subscription = @event.data.object
      subscription = ::Subscription.find_by(stripe_subscription_id: stripe_subscription.id)
      return { status: :subscription_not_found } unless subscription

      Rails.logger.info "[Stripe] Trial ending soon for user #{subscription.user_id}"
      BillingMailer.trial_ending_soon(subscription).deliver_later

      { status: :success, user: subscription.user, subscription: subscription }
    end

    def handle_invoice_paid
      stripe_invoice = @event.data.object
      invoice = ::Invoice.sync_from_stripe(stripe_invoice)
      { status: :success, user: invoice.user, subscription: invoice.subscription }
    end

    def handle_invoice_payment_failed
      stripe_invoice = @event.data.object
      invoice = ::Invoice.sync_from_stripe(stripe_invoice)

      Rails.logger.warn "[Stripe] Payment failed for user #{invoice.user_id}"
      BillingMailer.payment_failed(invoice).deliver_later if invoice.subscription

      { status: :success, user: invoice.user, subscription: invoice.subscription }
    end

    # PSD2 / 3D Secure: Stripe needs cardholder action to complete the charge.
    # We email the org owner a link to the hosted invoice so they can authenticate.
    def handle_invoice_payment_action_required
      stripe_invoice = @event.data.object
      invoice = ::Invoice.sync_from_stripe(stripe_invoice)

      Rails.logger.warn "[Stripe] Payment action required for user #{invoice.user_id}"
      BillingMailer.payment_action_required(invoice).deliver_later if invoice.subscription

      { status: :success, user: invoice.user, subscription: invoice.subscription }
    end

    def handle_invoice_created
      stripe_invoice = @event.data.object
      invoice = ::Invoice.sync_from_stripe(stripe_invoice)
      { status: :success, user: invoice.user, subscription: invoice.subscription }
    end

    def handle_invoice_finalized
      stripe_invoice = @event.data.object
      invoice = ::Invoice.sync_from_stripe(stripe_invoice)
      { status: :success, user: invoice.user, subscription: invoice.subscription }
    end

    def handle_customer_created
      customer = @event.data.object
      org = find_organization_from_metadata(customer.metadata)

      org&.update!(stripe_customer_id: customer.id) if org && org.stripe_customer_id.blank?

      { status: :success, user: org&.owner }
    end

    # Acknowledge customer.updated events (e.g., card change, address update).
    # We don't write back to User.email — Devise auth controls that — but
    # recording the event gives us an audit trail and resolves attribution.
    def handle_customer_updated
      customer = @event.data.object
      org = ::Organization.find_by(stripe_customer_id: customer.id)
      { status: :success, user: org&.owner }
    end

    def find_user_for_subscription(stripe_subscription)
      user = find_user_from_metadata(stripe_subscription.metadata)
      return user if user

      org = Organization.find_by(stripe_customer_id: stripe_subscription.customer)
      org&.owner
    end

    def find_user_from_metadata(metadata)
      user_id = metadata && metadata["user_id"]
      return nil if user_id.blank?

      User.find_by(id: user_id)
    end

    def find_organization_from_metadata(metadata)
      org_id = metadata && metadata["organization_id"]
      return nil if org_id.blank?

      Organization.find_by(id: org_id)
    end
  end
end
