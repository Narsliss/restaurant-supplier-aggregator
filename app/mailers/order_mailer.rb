class OrderMailer < ApplicationMailer
  def order_placed_notification(order)
    @order = order
    @chef = order.user
    @supplier = order.supplier
    @location = order.location
    @items = order.order_items.includes(:supplier_product)

    owner_emails = order.organization.owners.pluck(:email)
    return if owner_emails.empty?

    mail(
      to: owner_emails,
      subject: "[EnPlace Pro] New order from #{@chef.full_name} — #{@supplier&.name} — $#{'%.2f' % order.total_amount}"
    )
  end
end
