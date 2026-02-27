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
end
