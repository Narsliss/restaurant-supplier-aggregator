class SubscriptionsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_owner!, only: [:create, :billing_portal, :cancel_subscription, :reactivate]
  # TODO: Re-enable when subscription enforcement is active
  # skip_before_action :require_subscription, only: [:new, :create, :success, :cancel]

  def show
    @subscription = current_user.current_subscription
    @invoices = current_user.invoices.recent.limit(10)
  end

  def new
    # Pricing page for orgs without a subscription. Comp orgs see it too: that
    # is how they switch to paid without ever hitting the paywall.
    if current_user.current_subscription
      redirect_to subscription_path
      return
    end

    # Same rule Checkout applies, so the page never promises a trial the
    # charge won't honor (or the reverse).
    @trial_days = current_user.current_organization&.checkout_trial_days || 0
  rescue Stripe::StripeError => e
    Rails.logger.error "[Stripe] Trial eligibility check failed: #{e.message}"
    @trial_days = 0
  end

  def create
    org = current_user.current_organization

    # Never open a second Checkout while a subscription is alive. A past-due
    # restaurant fixes its card in the billing portal; a new subscription
    # would bill it twice once Stripe's retry succeeds.
    if org.current_subscription
      redirect_to subscription_path, alert: "You already have a subscription. Use Manage Billing to update your card."
      return
    end
    if (existing = org.live_stripe_subscription)
      Subscription.sync_from_stripe(existing, user: org.owner || current_user)
      redirect_to subscription_path, alert: "You already have a subscription. Use Manage Billing to update your card."
      return
    end

    session = org.create_checkout_session(
      user: current_user,
      success_url: success_subscription_url + "?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: cancel_subscription_url
    )

    # Use render + JS redirect instead of 302 — more reliable for cross-origin Stripe URLs
    @checkout_url = session.url
    render html: "<html><body><script>window.location.href = #{@checkout_url.to_json};</script></body></html>".html_safe
  rescue Stripe::StripeError => e
    Rails.logger.error "[Stripe] Checkout error: #{e.message}"
    redirect_to new_subscription_path, alert: "We couldn't open checkout. Please try again in a minute."
  end

  def success
    if params[:session_id].present?
      begin
        session = Stripe::Checkout::Session.retrieve(params[:session_id])
        org = current_user.current_organization

        if org && (org.stripe_customer_id.blank? || session.customer == org.stripe_customer_id)
          if session.subscription
            stripe_sub = Stripe::Subscription.retrieve(session.subscription)
            Subscription.sync_from_stripe(stripe_sub, user: current_user)
            org.update_column(:stripe_customer_id, session.customer) if org.stripe_customer_id.blank?
          end
        end
      rescue Stripe::StripeError => e
        Rails.logger.error "[Stripe] Error verifying session: #{e.message}"
      end
    end

    redirect_to root_path
  end

  def cancel
    # User canceled checkout
    redirect_to new_subscription_path
  end

  def billing_portal
    org = current_user.current_organization
    unless org&.stripe_customer_id.present?
      redirect_to subscription_path, alert: "No active billing account."
      return
    end

    session = org.create_billing_portal_session(return_url: subscription_url)

    redirect_to session.url, allow_other_host: true
  rescue Stripe::StripeError => e
    Rails.logger.error "[Stripe] Portal error: #{e.message}"
    redirect_to subscription_path, alert: "We couldn't open billing. Please try again in a minute."
  end

  def cancel_subscription
    subscription = current_user.current_subscription
    return redirect_to subscription_path unless subscription

    begin
      Stripe::Subscription.update(
        subscription.stripe_subscription_id,
        cancel_at_period_end: true
      )

      subscription.update!(cancel_at_period_end: true)

      redirect_to subscription_path
    rescue Stripe::StripeError => e
      Rails.logger.error "[Stripe] Cancel error: #{e.message}"
      redirect_to subscription_path
    end
  end

  def reactivate
    # The org's live subscription only: an old canceled row can still carry
    # cancel_at_period_end, and Stripe rejects updates to canceled subscriptions.
    subscription = current_user.current_subscription
    return redirect_to subscription_path unless subscription&.cancel_at_period_end?

    begin
      Stripe::Subscription.update(
        subscription.stripe_subscription_id,
        cancel_at_period_end: false
      )

      subscription.update!(cancel_at_period_end: false)

      redirect_to subscription_path
    rescue Stripe::StripeError => e
      Rails.logger.error "[Stripe] Reactivate error: #{e.message}"
      redirect_to subscription_path
    end
  end
end
