require "rails_helper"

RSpec.describe SignupBotGuard do
  let(:now) { Time.zone.parse("2026-11-03 12:00:00") }

  def params_with(rendered_at:, honeypot: nil)
    ActionController::Parameters.new(
      ep_ts: described_class.timestamp_token(now: rendered_at),
      ep_hp: honeypot
    )
  end

  it "passes a form filled in at a human pace with the honeypot empty" do
    expect(described_class.rejection_reason(params_with(rendered_at: now - 20.seconds), now: now)).to be_nil
  end

  it "passes at exactly the minimum fill time" do
    expect(described_class.rejection_reason(params_with(rendered_at: now - 3.seconds), now: now)).to be_nil
  end

  it "passes a form left open for days (no expiry on the timestamp)" do
    expect(described_class.rejection_reason(params_with(rendered_at: now - 5.days), now: now)).to be_nil
  end

  it "treats a whitespace-only honeypot as empty" do
    expect(described_class.rejection_reason(params_with(rendered_at: now - 20.seconds, honeypot: "  "), now: now)).to be_nil
  end

  it "rejects a filled honeypot" do
    expect(described_class.rejection_reason(params_with(rendered_at: now - 20.seconds, honeypot: "http://spam.example"), now: now))
      .to eq(:honeypot)
  end

  it "rejects a submit faster than the minimum fill time" do
    expect(described_class.rejection_reason(params_with(rendered_at: now - 2.seconds), now: now)).to eq(:too_fast)
  end

  it "rejects a submit with no timestamp (POSTed without loading the form)" do
    expect(described_class.rejection_reason(ActionController::Parameters.new({}), now: now)).to eq(:missing_timestamp)
  end

  it "rejects a forged timestamp" do
    forged = ActionController::Parameters.new(ep_ts: Base64.strict_encode64("1700000000"))
    expect(described_class.rejection_reason(forged, now: now)).to eq(:missing_timestamp)
  end
end
