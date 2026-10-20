# Admin page for the one-time Stripe test-mode cleanup (Billing::TestModeCutover).
# GET previews what would change; POST applies it. Both ask live Stripe first.
class Admin::BillingCutoversController < Admin::BaseController
  def show
    @live = Billing::TestModeCutover.live_key?
    @plan = Billing::TestModeCutover.new.plan if @live
    @retired = Billing::TestModeCutover.retired_subscriptions
  rescue Stripe::StripeError => e
    @error = e.message
    @retired = Billing::TestModeCutover.retired_subscriptions
  end

  def create
    plan = Billing::TestModeCutover.new.run!
    redirect_to admin_billing_cutover_path,
                notice: "Retired #{plan.subscriptions.size} test subscription(s) and cleared #{plan.organizations.size} test customer ID(s)."
  rescue Billing::TestModeCutover::NotLiveError
    redirect_to admin_billing_cutover_path, alert: 'Stripe is still on the test key. Set the live keys in Railway first.'
  rescue Stripe::StripeError => e
    redirect_to admin_billing_cutover_path, alert: "Stripe error, nothing was changed: #{e.message}"
  end
end
