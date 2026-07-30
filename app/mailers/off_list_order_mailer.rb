class OffListOrderMailer < ApplicationMailer
  # A chef ordered a product that wasn't on any matched list. It's now orderable
  # (they weren't blocked mid-shift), but it arrived with a single supplier and
  # no price comparison — so owners and managers get told to review it.
  def off_list_product_added(product_match)
    @match = product_match
    @chef = product_match.off_list_added_by
    @aggregated_list = product_match.aggregated_list
    @organization = @aggregated_list&.organization

    item = product_match.product_match_items.first
    @supplier = item&.supplier
    @supplier_list_item = item&.supplier_list_item
    @price = @supplier_list_item&.estimated_total_price || @supplier_list_item&.price

    recipients = notify_emails
    return if recipients.empty?

    mail(
      to: recipients,
      subject: "#{@chef&.first_name.presence || 'A chef'} ordered #{@match.display_name.to_s.truncate(40)} — not on your matched lists"
    )
  end

  private

  def notify_emails
    return [] unless @organization

    (@organization.owners.to_a + @organization.managers.to_a)
      .uniq
      .filter_map { |u| u.email.presence }
  end
end
