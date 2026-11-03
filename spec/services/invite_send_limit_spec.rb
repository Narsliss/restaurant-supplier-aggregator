require "rails_helper"

RSpec.describe InviteSendLimit do
  # Test env uses :null_store; the limit needs a real counter.
  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  let(:unpaid_org) { create(:organization) }
  let(:comp_org) { create(:organization, complimentary: true, complimentary_granted_at: Time.current) }

  it "allows an unpaid org up to LIMIT sends, then blocks" do
    (described_class::LIMIT - 1).times { described_class.record!(unpaid_org) }
    expect(described_class.allowed?(unpaid_org)).to be(true)

    described_class.record!(unpaid_org)
    expect(described_class.sent(unpaid_org)).to eq(described_class::LIMIT)
    expect(described_class.allowed?(unpaid_org)).to be(false)
  end

  it "counts per organization" do
    described_class::LIMIT.times { described_class.record!(unpaid_org) }
    expect(described_class.allowed?(create(:organization))).to be(true)
  end

  it "resets after the window from the FIRST send (later sends don't extend it)" do
    described_class.record!(unpaid_org)
    travel 6.days
    (described_class::LIMIT - 1).times { described_class.record!(unpaid_org) }
    expect(described_class.allowed?(unpaid_org)).to be(false)

    travel 1.day + 1.second
    expect(described_class.allowed?(unpaid_org)).to be(true)
  end

  it "never limits or counts a paid/complimentary org" do
    20.times { described_class.record!(comp_org) }
    expect(described_class.sent(comp_org)).to eq(0)
    expect(described_class.allowed?(comp_org)).to be(true)
  end
end
