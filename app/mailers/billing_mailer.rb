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

  # Sent when Stripe needs cardholder action (3D Secure / SCA) to complete a charge.
  def payment_action_required(invoice)
    @invoice = invoice
    @subscription = invoice.subscription
    @org = @subscription&.organization || @subscription&.user&.current_organization
    @owner = @org&.owner || invoice.user
    @amount = invoice.formatted_amount_due
    @hosted_invoice_url = invoice.hosted_invoice_url

    return unless @owner&.email

    mail(
      to: @owner.email,
      subject: "Action required to complete your EnPlace Pro payment"
    )
  end

  # Sent to super admin when a SeatSyncService call fails — revenue-leak risk.
  def seat_sync_failed(organization, error_message)
    @org = organization
    @error_message = error_message
    @admin = User.super_admin

    return unless @admin&.email

    mail(
      to: @admin.email,
      subject: "[Action] Seat sync failed for #{@org.name}"
    )
  end
end
