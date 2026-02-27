class Admin::RevenuesController < Admin::BaseController
  def show
    # MRR
    active_monthly = Subscription.where(status: %w[active trialing]).where(interval: 'month')
    @mrr = active_monthly.sum(:amount_cents) / 100.0

    # Subscription breakdown
    @sub_by_status = Subscription.group(:status).count

    # Monthly revenue (last 12 months)
    @monthly_revenue = Invoice.paid
      .where('paid_at >= ?', 12.months.ago)
      .group(Arel.sql("date_trunc('month', paid_at)"))
      .sum(:amount_paid_cents)
      .transform_keys { |k| k.to_date }
      .transform_values { |v| v / 100.0 }
      .sort_by { |k, _| k }

    # Counts
    @active_count   = Subscription.where(status: 'active').count
    @trialing_count = Subscription.where(status: 'trialing').count
    @past_due_count = Subscription.past_due.count
    @canceled_count = Subscription.canceled.count

    # Trials expiring soon
    @trials_expiring = Subscription.where(status: 'trialing')
                                    .where('trial_end <= ?', 7.days.from_now)
                                    .includes(:user)
                                    .order(:trial_end)

    # Recent invoices
    @recent_invoices = Invoice.order(created_at: :desc).includes(:user, :subscription).limit(20)
  end
end
