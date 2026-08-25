class MatchingMailer < ApplicationMailer
  # A new customer's first matched list has finished building. Signing up is
  # followed by a wait — credentials validate, guides sync, matching runs, the
  # catalog fills the gaps — and nothing tells them when it's done. This does.
  #
  # Sent once per organization, ever; see MatchCompletionNotifier for the gate.
  def list_ready(aggregated_list)
    @aggregated_list = aggregated_list
    @organization = aggregated_list.organization
    @owner = @organization&.owner
    # AggregatedList carries a bare location_id, not an association.
    @location = Location.find_by(id: aggregated_list.location_id)

    @total = aggregated_list.product_matches.where.not(match_status: 'rejected').count
    @unmatched = aggregated_list.product_matches.unmatched.count
    @matched = @total - @unmatched
    @suppliers = aggregated_list.supplier_lists.includes(:supplier).map(&:supplier).uniq

    return if @owner&.email.blank?

    mail(
      to: @owner.email,
      subject: "Your price comparison is ready — #{@matched} #{'product'.pluralize(@matched)} matched"
    )
  end
end
