class Admin::DashboardController < Admin::BaseController
  def index
    # -- Top-line stats --
    @stats = {
      total_users:          User.where(role: 'user').count,
      total_organizations:  Organization.count,
      active_subscriptions: Subscription.active_or_trialing.count,
      scraper_success_rate: ScrapingLog.success_rate_in_last(24.hours)
    }

    # -- Growth: new users/orgs in last 30 days vs prior 30 days --
    @new_users_30d     = User.where(role: 'user').where('created_at >= ?', 30.days.ago).count
    @new_users_prev_30 = User.where(role: 'user').where(created_at: 60.days.ago..30.days.ago).count
    @new_orgs_30d      = Organization.where('created_at >= ?', 30.days.ago).count

    # -- Recent activity --
    @recent_signups = User.where(role: 'user').order(created_at: :desc).limit(5)
    @recent_logins  = User.where(role: 'user')
                          .where.not(current_sign_in_at: nil)
                          .order(current_sign_in_at: :desc)
                          .limit(5)

    # -- Alerts: things that need attention --
    @alerts = []

    failed_creds = SupplierCredential.where(status: %w[failed expired]).count
    @alerts << { level: :warning, message: "#{failed_creds} supplier credential(s) need attention" } if failed_creds > 0

    failed_scrapes_24h = ScrapingLog.in_last(24.hours).failed.count
    @alerts << { level: :error, message: "#{failed_scrapes_24h} scraping failure(s) in last 24 hours" } if failed_scrapes_24h > 0

    past_due = Subscription.past_due.count
    @alerts << { level: :warning, message: "#{past_due} subscription(s) past due" } if past_due > 0

    locked_users = User.where.not(locked_at: nil).count
    @alerts << { level: :info, message: "#{locked_users} locked user account(s)" } if locked_users > 0
  end
end
