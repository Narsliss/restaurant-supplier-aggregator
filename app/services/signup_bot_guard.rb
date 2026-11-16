# frozen_string_literal: true

# Cheap, invisible bot checks for the sign-up form (POST /users).
#
# Two checks, no third-party service and nothing a real person sees:
#
# 1. Honeypot — a text field hidden off-screen. People never see or fill it;
#    form-spamming bots fill every field they find.
# 2. Minimum fill time — the form carries a signed timestamp of when it was
#    rendered. A submit sooner than MIN_FILL_SECONDS, or with no valid
#    timestamp (a bot POSTing without ever loading the page), is rejected.
#
# A rejected submit re-renders the form with a "please try again" message and
# a fresh timestamp, so a real person caught by mistake gets through on the
# second try. Every rejection is logged with a [SignupBotGuard] tag so false
# positives are visible in the Railway logs.
#
# See docs/signup-bot-guard.md.
class SignupBotGuard
  HONEYPOT_PARAM = :ep_hp
  TIMESTAMP_PARAM = :ep_ts
  MIN_FILL_SECONDS = 3

  def self.verifier
    Rails.application.message_verifier(:signup_bot_guard)
  end

  # Signed render time, embedded in the form as a hidden field.
  def self.timestamp_token(now: Time.current)
    verifier.generate(now.to_i)
  end

  # Returns nil when the submit looks human, or a Symbol reason when it should
  # be rejected: :honeypot, :missing_timestamp, :too_fast.
  def self.rejection_reason(params, now: Time.current)
    return :honeypot if params[HONEYPOT_PARAM].present?

    rendered_at = verifier.verified(params[TIMESTAMP_PARAM].to_s)
    return :missing_timestamp unless rendered_at.is_a?(Integer)

    return :too_fast if now.to_i - rendered_at < MIN_FILL_SECONDS

    nil
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ArgumentError
    :missing_timestamp
  end
end
