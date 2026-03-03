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
    # Show pricing page for users without subscription
    if current_user.subscribed?
      redirect_to subscription_path
    end
  end

  def create
    org = current_user.current_organization
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
    redirect_to new_subscription_path
  end

  def success
    # Verify the checkout session
    if params[:session_id].present?
      begin
        session = Stripe::Checkout::Session.retrieve(params[:session_id])

        if session.customer == current_user.stripe_customer_id ||
           current_user.stripe_customer_id.blank?

          # Sync the subscription
          if session.subscription
            stripe_sub = Stripe::Subscription.retrieve(session.subscription)
            Subscription.sync_from_stripe(stripe_sub, user: current_user)
            current_user.update!(stripe_customer_id: session.customer) unless current_user.stripe_customer_id
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
    session = current_user.create_billing_portal_session(
      return_url: subscription_url
    )

    redirect_to session.url, allow_other_host: true
  rescue Stripe::StripeError => e
    Rails.logger.error "[Stripe] Portal error: #{e.message}"
    redirect_to subscription_path
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
    subscription = current_user.subscriptions.find_by(cancel_at_period_end: true)
    return redirect_to subscription_path unless subscription

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
