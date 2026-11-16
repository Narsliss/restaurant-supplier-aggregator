# frozen_string_literal: true

# Caps how many invitation emails an organization that hasn't paid can send.
#
# Owners invite their team during onboarding, BEFORE subscribing, so the
# invite pages are exempt from the subscription gate. The existing seat limit
# (5 seats -> 4 pending invites at once) is not enough on its own: canceling an
# invite frees its seat, so cancel-and-reinvite could send unlimited emails,
# with attacker-chosen org/inviter names, from our sending domain.
#
# This counts every invite email (new invites AND resends) an unpaid org sends,
# in Rails.cache (Solid Cache in production), for WINDOW from the first send.
# Canceling an invite does not give a send back. Paid and complimentary orgs
# (Organization#subscribed?) are never limited.
#
# See docs/signup-bot-guard.md.
class InviteSendLimit
  LIMIT = 10
  WINDOW = 7.days
  MESSAGE = "You've sent the most invitations allowed before subscribing. Subscribe to invite more people."

  def self.allowed?(organization)
    return true if organization.subscribed?

    sent(organization) < LIMIT
  end

  # Call once per invite email actually queued.
  def self.record!(organization)
    return if organization.subscribed?

    Rails.cache.increment(key(organization), 1, expires_in: WINDOW)
  end

  def self.sent(organization)
    Rails.cache.read(key(organization)).to_i
  end

  def self.key(organization)
    "invite_send_limit/org/#{organization.id}"
  end
end
