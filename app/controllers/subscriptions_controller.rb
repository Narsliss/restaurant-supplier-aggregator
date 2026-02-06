class SubscriptionsController < ApplicationController
  before_action :authenticate_user!
  skip_before_action :require_subscription, only: [:new, :create, :success, :cancel]

  def show
    @subscription = current_user.current_subscription
    @invoices = current_user.invoices.recent.limit(10)
  end

  def new
    # Show pricing page for users without subscription
    if current_user.subscribed?
      redirect_to subscription_path, notice: "You already have an active subscription."
    end
  end

  def create
    session = current_user.create_checkout_session(
      success_url: subscription_success_url + "?session_id={CHECKOUT_SESSION_ID}",
      cancel_url: subscription_cancel_url
    )

    redirect_to session.url, allow_other_host: true
  rescue Stripe::StripeError => e
    Rails.logger.error "[Stripe] Checkout error: #{e.message}"
    redirect_to new_subscription_path, alert: "Unable to start checkout. Please try again."
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

    redirect_to root_path, notice: "Welcome to SupplierHub Pro! Your subscription is now active."
  end

  def cancel
    # User canceled checkout
    redirect_to new_subscription_path, notice: "Checkout was canceled. You can try again when you're ready."
  end

  def billing_portal
    session = current_user.create_billing_portal_session(
      return_url: subscription_url
    )

    redirect_to session.url, allow_other_host: true
  rescue Stripe::StripeError => e
    Rails.logger.error "[Stripe] Portal error: #{e.message}"
    redirect_to subscription_path, alert: "Unable to access billing portal. Please try again."
  end

  def cancel_subscription
    subscription = current_user.current_subscription
    return redirect_to subscription_path, alert: "No active subscription found." unless subscription

    begin
      Stripe::Subscription.update(
        subscription.stripe_subscription_id,
        cancel_at_period_end: true
      )

      subscription.update!(cancel_at_period_end: true)

      redirect_to subscription_path, notice: "Your subscription will be canceled at the end of the billing period."
    rescue Stripe::StripeError => e
      Rails.logger.error "[Stripe] Cancel error: #{e.message}"
      redirect_to subscription_path, alert: "Unable to cancel subscription. Please try again or contact support."
    end
  end

  def reactivate
    subscription = current_user.subscriptions.find_by(cancel_at_period_end: true)
    return redirect_to subscription_path, alert: "No subscription to reactivate." unless subscription

    begin
      Stripe::Subscription.update(
        subscription.stripe_subscription_id,
        cancel_at_period_end: false
      )

      subscription.update!(cancel_at_period_end: false)

      redirect_to subscription_path, notice: "Your subscription has been reactivated!"
    rescue Stripe::StripeError => e
      Rails.logger.error "[Stripe] Reactivate error: #{e.message}"
      redirect_to subscription_path, alert: "Unable to reactivate subscription. Please try again."
    end
  end
end
