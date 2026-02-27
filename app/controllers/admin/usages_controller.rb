class Admin::UsagesController < Admin::BaseController
  def show
    @total_users = User.where(role: 'user').count
    @active_7d  = User.where(role: 'user').where('current_sign_in_at >= ?', 7.days.ago).count
    @active_30d = User.where(role: 'user').where('current_sign_in_at >= ?', 30.days.ago).count
    @dormant    = User.where(role: 'user').where('current_sign_in_at < ? OR current_sign_in_at IS NULL', 30.days.ago).count

    # Feature adoption
    @users_with_orders = User.where(role: 'user').joins(:orders).distinct.count
    @users_with_creds  = User.where(role: 'user').joins(:supplier_credentials).where(supplier_credentials: { status: 'active' }).distinct.count
    @users_with_lists  = User.where(role: 'user').joins(:order_lists).distinct.count
    @orgs_with_locations = Organization.joins(:locations).distinct.count
    @total_orgs = Organization.count

    # Weekly signups (12 weeks)
    @weekly_signups = User.where(role: 'user')
      .where('created_at >= ?', 12.weeks.ago)
      .group(Arel.sql("date_trunc('week', created_at)"))
      .count
      .transform_keys { |k| k.to_date }
      .sort_by { |k, _| k }

    # Weekly orders (12 weeks)
    @weekly_orders = Order.where('created_at >= ?', 12.weeks.ago)
      .group(Arel.sql("date_trunc('week', created_at)"))
      .count
      .transform_keys { |k| k.to_date }
      .sort_by { |k, _| k }

    # Login frequency
    @login_distribution = {
      'Never' => User.where(role: 'user', sign_in_count: 0).count,
      '1x' => User.where(role: 'user', sign_in_count: 1).count,
      '2-10' => User.where(role: 'user', sign_in_count: 2..10).count,
      '11-50' => User.where(role: 'user', sign_in_count: 11..50).count,
      '50+' => User.where(role: 'user').where('sign_in_count > 50').count
    }

    # Top users
    @top_users = User.where(role: 'user')
                     .where.not(current_sign_in_at: nil)
                     .includes(:current_organization)
                     .order(sign_in_count: :desc)
                     .limit(10)
  end
end
