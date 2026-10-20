module Billing
  # One-time cleanup after Stripe moves from test keys to live keys
  # (docs/stripe-go-live.md, blocker 4). Rows made under the test key don't
  # exist in live Stripe and will never receive another webhook, so:
  #   - test subscriptions still marked active/trialing/past_due would grant
  #     free access forever -> retired here (status canceled, reason in metadata)
  #   - test customer IDs on organizations -> cleared
  #
  # Every row is checked against Stripe under the current (live) key first;
  # anything live Stripe knows about is left alone, so a restaurant that
  # already subscribed for real is never touched. No emails, no Stripe
  # writes, safe to run again. Any Stripe error other than "not found" stops
  # the whole run before anything changes.
  class TestModeCutover
    RETIRED_REASON = 'stripe_test_mode_cutover'.freeze

    class NotLiveError < StandardError; end

    Plan = Struct.new(:subscriptions, :organizations, keyword_init: true) do
      def empty?
        subscriptions.empty? && organizations.empty?
      end
    end

    def self.live_key?
      ::Stripe.api_key.to_s.start_with?('sk_live_', 'rk_live_')
    end

    def self.retired_subscriptions
      ::Subscription.where("metadata->>'retired_reason' = ?", RETIRED_REASON).includes(:organization).order(:id)
    end

    def plan
      raise NotLiveError, 'Stripe is still on a test key' unless self.class.live_key?

      Plan.new(
        subscriptions: ::Subscription.with_access.includes(:organization).order(:id)
                                     .reject { |sub| subscription_exists?(sub.stripe_subscription_id) },
        organizations: ::Organization.where.not(stripe_customer_id: [nil, '']).order(:id)
                                     .reject(&:stripe_customer_exists?)
      )
    end

    def run!
      plan = self.plan
      now = Time.current

      ActiveRecord::Base.transaction do
        plan.subscriptions.each do |sub|
          sub.update_columns(
            status: 'canceled',
            canceled_at: now,
            ended_at: now,
            cancel_at_period_end: false,
            metadata: (sub.metadata || {}).merge('retired_reason' => RETIRED_REASON, 'retired_at' => now.iso8601),
            updated_at: now
          )
        end
        plan.organizations.each { |org| org.update_columns(stripe_customer_id: nil, updated_at: now) }
      end

      Rails.logger.info "[Billing] Test-mode cutover: retired #{plan.subscriptions.size} subscription(s), " \
                        "cleared #{plan.organizations.size} customer ID(s)"
      plan
    end

    private

    def subscription_exists?(stripe_subscription_id)
      ::Stripe::Subscription.retrieve(stripe_subscription_id)
      true
    rescue ::Stripe::InvalidRequestError => e
      raise unless e.code == 'resource_missing'

      false
    end
  end
end
