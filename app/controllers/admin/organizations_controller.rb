class Admin::OrganizationsController < Admin::BaseController
  def index
    @organizations = Organization.includes(:subscriptions)
                                  .order(params[:sort] == 'name' ? :name : { created_at: :desc })

    @organizations = @organizations.where('name ILIKE ?', "%#{params[:q]}%") if params[:q].present?
    @organizations = @organizations.where(active: false) if params[:filter] == 'suspended'

    @page = (params[:page] || 1).to_i
    @per_page = 25
    @total_count = @organizations.count
    @organizations = @organizations.offset((@page - 1) * @per_page).limit(@per_page)
  end

  def show
    @org = Organization.find(params[:id])
    @members = @org.memberships.includes(:user).where(active: true).order(:role)
    @pending_invitations = @org.organization_invitations.where(accepted_at: nil).where('expires_at > ?', Time.current)
    @credentials = @org.supplier_credentials.includes(:supplier, :user).order(created_at: :desc)
    @subscription = @org.subscriptions.where(status: %w[active trialing past_due]).order(created_at: :desc).first
    @locations = @org.locations
    @recent_orders = @org.orders.includes(:supplier, :user).order(created_at: :desc).limit(10)
    @invoices = Invoice.joins(:subscription).where(subscriptions: { user_id: @org.memberships.select(:user_id) }).order(created_at: :desc).limit(10)

    @stats = {
      member_count: @org.member_count,
      seat_limit: @org.seat_limit,
      location_count: @locations.count,
      total_orders: @org.orders.count,
      total_spend: @org.orders.where(status: %w[submitted confirmed]).sum(:total_amount)
    }
  end

  def suspend
    org = Organization.find(params[:id])
    org.update!(active: false, suspended_at: Time.current)
    redirect_to admin_organization_path(org), notice: "#{org.name} has been suspended."
  end

  def reactivate
    org = Organization.find(params[:id])
    org.update!(active: true, suspended_at: nil)
    redirect_to admin_organization_path(org), notice: "#{org.name} has been reactivated."
  end

  def reinvite
    org = Organization.find(params[:id])
    invitation = org.organization_invitations.find(params[:invitation_id])
    invitation.resend!
    redirect_to admin_organization_path(org), notice: "Invitation resent to #{invitation.email}."
  end

  def grant_complimentary
    org = Organization.find(params[:id])
    reason = params[:reason].presence || "Granted by admin"
    org.grant_complimentary!(by: current_user, reason: reason)
    redirect_to admin_organization_path(org), notice: "#{org.name} now has complimentary access."
  end

  def revoke_complimentary
    org = Organization.find(params[:id])
    org.revoke_complimentary!
    redirect_to admin_organization_path(org), notice: "Complimentary access revoked for #{org.name}."
  end

  def extend_trial
    org = Organization.find(params[:id])
    subscription = org.subscriptions.where(status: %w[active trialing]).order(created_at: :desc).first

    unless subscription&.stripe_subscription_id
      redirect_to admin_organization_path(org), alert: "No active subscription to extend trial on."
      return
    end

    days = (params[:days].presence || 14).to_i
    new_trial_end = (subscription.trial_end || Time.current) + days.days

    begin
      Stripe::Subscription.update(
        subscription.stripe_subscription_id,
        trial_end: new_trial_end.to_i
      )
      # Webhook will sync the updated trial_end back to our DB
      redirect_to admin_organization_path(org), notice: "Trial extended by #{days} days (until #{new_trial_end.strftime('%b %-d, %Y')})."
    rescue Stripe::StripeError => e
      redirect_to admin_organization_path(org), alert: "Stripe error: #{e.message}"
    end
  end

  def cancel_subscription
    org = Organization.find(params[:id])
    subscription = org.subscriptions.where(status: %w[active trialing]).order(created_at: :desc).first

    unless subscription&.stripe_subscription_id
      redirect_to admin_organization_path(org), alert: "No active subscription to cancel."
      return
    end

    begin
      Stripe::Subscription.update(
        subscription.stripe_subscription_id,
        cancel_at_period_end: true
      )
      # Webhook will sync the cancellation back to our DB
      redirect_to admin_organization_path(org), notice: "Subscription will cancel at end of current period."
    rescue Stripe::StripeError => e
      redirect_to admin_organization_path(org), alert: "Stripe error: #{e.message}"
    end
  end
end
