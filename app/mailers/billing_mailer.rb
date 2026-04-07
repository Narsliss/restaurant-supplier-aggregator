class BillingMailer < ApplicationMailer
  def trial_ending_soon(subscription)
    @subscription = subscription
    @org = subscription.organization || subscription.user&.current_organization
    @owner = @org&.owner || subscription.user
    @trial_end = subscription.trial_end
    @days_remaining = subscription.trial_days_remaining

    return unless @owner&.email

    mail(
      to: @owner.email,
      subject: "Your EnPlace Pro trial ends in #{@days_remaining} days"
    )
  end

  def payment_failed(invoice)
    @invoice = invoice
    @subscription = invoice.subscription
    @org = @subscription&.organization || @subscription&.user&.current_organization
    @owner = @org&.owner || invoice.user
    @amount = invoice.formatted_amount_due

    return unless @owner&.email

    mail(
      to: @owner.email,
      subject: "Payment failed for your EnPlace Pro subscription"
    )
  end

  def subscription_canceled(subscription)
    @subscription = subscription
    @org = subscription.organization || subscription.user&.current_organization
    @owner = @org&.owner || subscription.user
    @access_until = subscription.current_period_end

    return unless @owner&.email

    mail(
      to: @owner.email,
      subject: "Your EnPlace Pro subscription has been canceled"
    )
  end

  def welcome(subscription)
    @subscription = subscription
    @org = subscription.organization || subscription.user&.current_organization
    @owner = @org&.owner || subscription.user

    return unless @owner&.email

    mail(
      to: @owner.email,
      subject: "Welcome to EnPlace Pro!"
    )
  end
end
