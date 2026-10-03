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

  # The order was NOT placed (or can't be confirmed) and the chef didn't see
  # it in the app. Goes to the chef who placed it and the org owner(s).
  # See OrderFailureAlertJob.
  def order_not_placed(order, kind: 'not_placed')
    @order = order
    @kind = kind
    @chef = order.user
    @supplier_name = order.supplier&.name || order.supplier_name || 'the supplier'
    @location = order.location
    @items = order.order_items.includes(:supplier_product)

    recipients = ([@chef&.email] + Array(order.organization&.owners&.pluck(:email))).compact.uniq
    return if recipients.empty?

    when_text = order.delivery_date ? " for #{order.delivery_date.strftime('%a %b %-d')}" : ''
    subject = case kind
              when 'unconfirmed' then "Check with #{@supplier_name}: your order#{when_text} may not have gone through"
              when 'stuck' then "Your #{@supplier_name} order#{when_text} hasn't gone through yet"
              else "NOT PLACED: your #{@supplier_name} order#{when_text}"
              end

    mail(to: recipients, subject: "[EnPlace Pro] #{subject}")
  end
end
