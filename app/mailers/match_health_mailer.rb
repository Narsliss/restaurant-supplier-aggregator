class MatchHealthMailer < ApplicationMailer
  # See MatchHealthCheckJob.
  def degraded(new_empty_row_ids:, new_stranded_ids:, total_empty:, total_stranded:, first_check: false)
    admin = User.super_admin
    return if admin&.email.blank?

    @first_check = first_check
    @total_empty = total_empty
    @total_stranded = total_stranded
    @rows = ProductMatch.where(id: new_empty_row_ids).includes(aggregated_list: :organization)
                        .order(:aggregated_list_id, :id)
    @last_removals = MatchItemRemoval.where(product_match_id: new_empty_row_ids)
                                     .order(:created_at).group_by(&:product_match_id)
                                     .transform_values(&:last)
    @stranded = OrderListItem.where(id: new_stranded_ids).includes(:order_list, :product_match)

    subject = if first_check
                "Matched-list health: #{total_empty} empty rows, #{total_stranded} order-list entries on them (first check)"
              else
                "Matched lists degraded: #{new_empty_row_ids.size} newly empty rows, " \
                  "#{new_stranded_ids.size} newly stranded order-list entries"
              end
    mail(to: admin.email, subject: subject)
  end
end
