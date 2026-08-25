# Emails a new customer once, when their first matched list finishes building.
#
# Signing up is followed by a silent wait — credentials validate, order guides
# sync, matching runs, and the catalog search fills the gaps. Nothing told them
# when it was done, so they either sat on the page or drifted off. This closes
# that loop.
#
# "New sign up" means the organization's FIRST list to finish, ever. Every
# later list, and every re-run of matching on this one, stays quiet — the email
# is an onboarding moment, not a status feed.
class MatchCompletionNotifier
  def self.call(aggregated_list)
    new(aggregated_list).call
  end

  def initialize(aggregated_list)
    @list = aggregated_list
  end

  def call
    return unless eligible?
    return unless claim!

    MatchingMailer.list_ready(@list).deliver_later
    Rails.logger.info "[MatchCompletion] Emailed #{@list.organization&.name} for list #{@list.id}"
    true
  rescue StandardError => e
    # A failed email must never take down the matching pipeline that called us.
    Rails.logger.error "[MatchCompletion] Failed for list #{@list&.id}: #{e.class}: #{e.message}"
    false
  end

  private

  def eligible?
    return false if @list.blank?
    return false unless @list.matched?
    # Catalog search is still filling in the gaps — the counts would be wrong
    # and the chef would open a list that's still moving.
    return false if @list.searching_catalog?
    return false if @list.completion_emailed_at.present?

    org = @list.organization
    return false if org.blank?
    return false if org.owner&.email.blank?

    # Nothing to celebrate on an empty list.
    return false if @list.product_matches.where.not(match_status: 'rejected').none?

    # Their first finished list, or nothing at all.
    !org.aggregated_lists.where.not(completion_emailed_at: nil).exists?
  end

  # Stamp before sending, conditionally, so two jobs finishing at once can't
  # both send. Whoever wins the UPDATE owns the email.
  def claim!
    AggregatedList.where(id: @list.id, completion_emailed_at: nil)
                  .update_all(completion_emailed_at: Time.current)
                  .positive?
  end
end
