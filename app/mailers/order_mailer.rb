class OrderMailer < ApplicationMailer
  def order_submitted(order)
    @order = order
    @user = order.user
    mail(to: @user.email, subject: "Order ##{order.id} Submitted Successfully")
  end

  def order_failed(order)
    @order = order
    @user = order.user
    mail(to: @user.email, subject: "Order ##{order.id} Failed - Action Required")
  end

  def order_confirmed(order)
    @order = order
    @user = order.user
    mail(to: @user.email, subject: "Order ##{order.id} Confirmed by #{order.supplier.name}")
  end
end
