class OrderMailer < ApplicationMailer
  def order_submitted(order)
    @order = order
    @user = order.user
    mail(to: @user.email, subject: "Order ##{order.id} Submitted Successfully")
  end

  def order_failed(order, error_message = nil)
    @order = order
    @user = order.user
    @error_message = error_message
    mail(to: @user.email, subject: "Order ##{order.id} Failed - Action Required")
  end

  def order_confirmed(order)
    @order = order
    @user = order.user
    mail(to: @user.email, subject: "Order ##{order.id} Confirmed by #{order.supplier.name}")
  end

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
      subject: "[SupplierHub] New order from #{@chef.full_name} — #{@supplier&.name} — $#{'%.2f' % order.total_amount}"
    )
  end
end
