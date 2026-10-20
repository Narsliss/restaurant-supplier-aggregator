require 'rails_helper'

RSpec.describe Billing::TestModeCutover do
  let(:owner) { create(:user, :with_organization) }
  let(:org) { owner.current_organization }
  let(:live_owner) { create(:user, :with_organization) }
  let(:live_org) { live_owner.current_organization }

  let!(:test_sub) { create(:subscription, user: owner, organization_id: org.id, stripe_subscription_id: 'sub_test_era') }
  let!(:live_sub) { create(:subscription, user: live_owner, organization_id: live_org.id, stripe_subscription_id: 'sub_live_real') }
  let!(:old_canceled) { create(:subscription, :canceled, user: owner, organization_id: org.id, stripe_subscription_id: 'sub_long_gone') }

  def resource_missing
    ::Stripe::InvalidRequestError.new('No such object', 'id', code: 'resource_missing')
  end

  def stripe_knows(subscriptions:, customers:)
    allow(::Stripe::Subscription).to receive(:retrieve) do |id|
      raise resource_missing unless subscriptions.include?(id)

      ::Stripe::Subscription.construct_from(id: id, object: 'subscription')
    end
    allow(::Stripe::Customer).to receive(:retrieve) do |id|
      raise resource_missing unless customers.include?(id)

      ::Stripe::Customer.construct_from(id: id, object: 'customer')
    end
  end

  before do
    org.update!(stripe_customer_id: 'cus_test_era')
    live_org.update!(stripe_customer_id: 'cus_live_real')
  end

  context 'with a live key' do
    before do
      allow(::Stripe).to receive(:api_key).and_return('sk_live_example')
      stripe_knows(subscriptions: ['sub_live_real'], customers: ['cus_live_real'])
    end

    it 'plans to retire only the subscriptions and customers live Stripe does not know' do
      plan = described_class.new.plan
      expect(plan.subscriptions).to contain_exactly(test_sub)
      expect(plan.organizations).to contain_exactly(org)
    end

    it 'retires test subscriptions and clears test customer IDs, leaving live ones alone' do
      described_class.new.run!

      expect(test_sub.reload.status).to eq('canceled')
      expect(test_sub.metadata['retired_reason']).to eq('stripe_test_mode_cutover')
      expect(org.reload.stripe_customer_id).to be_nil
      expect(org.subscribed?).to be false

      expect(live_sub.reload.status).to eq('active')
      expect(live_org.reload.stripe_customer_id).to eq('cus_live_real')
      expect(old_canceled.reload.metadata).not_to have_key('retired_reason')
    end

    it 'sends no emails' do
      expect { described_class.new.run! }.not_to have_enqueued_mail
    end

    it 'leaves complimentary access in place' do
      org.grant_complimentary!(by: owner, reason: 'Founding customer')
      described_class.new.run!
      expect(org.reload.subscribed?).to be true
    end

    it 'is safe to run twice' do
      described_class.new.run!
      plan = described_class.new.run!
      expect(plan).to be_empty
      expect(described_class.retired_subscriptions).to contain_exactly(test_sub)
    end

    it 'changes nothing when Stripe fails with anything other than not-found' do
      allow(::Stripe::Subscription).to receive(:retrieve).and_raise(::Stripe::APIConnectionError.new('timeout'))

      expect { described_class.new.run! }.to raise_error(::Stripe::APIConnectionError)
      expect(test_sub.reload.status).to eq('active')
      expect(org.reload.stripe_customer_id).to eq('cus_test_era')
    end
  end

  context 'with a test key' do
    before { allow(::Stripe).to receive(:api_key).and_return('sk_test_example') }

    it 'refuses to run, so test subscriptions are never retired while still in test mode' do
      expect { described_class.new.run! }.to raise_error(described_class::NotLiveError)
      expect(test_sub.reload.status).to eq('active')
    end
  end
end
