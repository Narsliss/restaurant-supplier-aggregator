class SupplierOrderMailer < ApplicationMailer
  def order_email(order, pdf_data)
    @order = order
    @supplier = order.supplier
    @location = order.location
    @organization = order.organization || order.user.current_organization

    attachments["order-#{order.id}-#{Date.current.iso8601}.pdf"] = {
      mime_type: 'application/pdf',
      content: pdf_data
    }

    mail(
      to: @supplier.contact_email,
      reply_to: order.user.email,
      subject: "Order from #{@organization.name} - #{Date.current.strftime('%b %d, %Y')}"
    )
  end
end
