require 'rails_helper'

RSpec.describe Organization, 'billing', type: :model do
  let(:owner) { create(:user, :with_organization) }
  let(:org) { owner.current_organization }

  def resource_missing
    ::Stripe::InvalidRequestError.new('No such customer', 'id', code: 'resource_missing')
  end

  describe '#current_subscription / #subscribed?' do
    # Regression: past_due was excluded, so a declined card locked the
    # restaurant out and offered it a second Checkout (double billing).
    it 'includes a past_due subscription, which keeps access' do
      sub = create(:subscription, :past_due, user: owner, organization_id: org.id)
      expect(org.current_subscription).to eq(sub)
      expect(org.subscribed?).to be true
    end

    it 'excludes canceled subscriptions' do
      create(:subscription, :canceled, user: owner, organization_id: org.id)
      expect(org.current_subscription).to be_nil
      expect(org.subscribed?).to be false
    end
  end

  describe '#end_complimentary_for!' do
    before { org.grant_complimentary!(by: owner, reason: 'Founding customer') }

    it 'ends comp when the subscription grants access' do
      org.end_complimentary_for!(build(:subscription, status: 'active'))
      expect(org.reload.complimentary).to be false
    end

    it 'leaves comp alone for a subscription without access' do
      org.end_complimentary_for!(build(:subscription, status: 'incomplete'))
      expect(org.reload.complimentary).to be true
    end
  end

  describe '#extra_seat_count' do
    it 'counts non-owner seats beyond the included five' do
      7.times { create(:membership, organization: org, user: create(:user), role: 'chef', active: true) }
      expect(org.extra_seat_count).to eq(2)
    end

    it 'is zero at or under the included seats' do
      expect(org.extra_seat_count).to eq(0)
    end
  end

  describe '#find_or_create_stripe_customer' do
    let(:new_customer) { ::Stripe::Customer.construct_from(id: 'cus_live_new', object: 'customer') }

    # Regression for the live cutover: every org holds a test-mode customer ID,
    # which a live key reports as missing.
    it 'replaces a saved customer that no longer exists in this Stripe mode' do
      org.update!(stripe_customer_id: 'cus_test_old')
      allow(::Stripe::Customer).to receive(:retrieve).with('cus_test_old').and_raise(resource_missing)
      allow(::Stripe::Customer).to receive(:create).and_return(new_customer)

      expect(org.find_or_create_stripe_customer).to eq(new_customer)
      expect(org.reload.stripe_customer_id).to eq('cus_live_new')
    end

    it 'replaces a customer deleted in the dashboard' do
      org.update!(stripe_customer_id: 'cus_deleted')
      allow(::Stripe::Customer).to receive(:retrieve)
        .and_return(::Stripe::Customer.construct_from(id: 'cus_deleted', object: 'customer', deleted: true))
      allow(::Stripe::Customer).to receive(:create).and_return(new_customer)

      org.find_or_create_stripe_customer
      expect(org.reload.stripe_customer_id).to eq('cus_live_new')
    end

    it 'reuses an existing customer' do
      existing = ::Stripe::Customer.construct_from(id: 'cus_ok', object: 'customer')
      org.update!(stripe_customer_id: 'cus_ok')
      allow(::Stripe::Customer).to receive(:retrieve).and_return(existing)
      expect(::Stripe::Customer).not_to receive(:create)

      expect(org.find_or_create_stripe_customer).to eq(existing)
    end

    it 'does not swallow other Stripe errors' do
      org.update!(stripe_customer_id: 'cus_ok')
      allow(::Stripe::Customer).to receive(:retrieve).and_raise(::Stripe::APIConnectionError.new('timeout'))

      expect { org.find_or_create_stripe_customer }.to raise_error(::Stripe::APIConnectionError)
    end
  end

  describe '#checkout_trial_days' do
    let(:config) { Rails.application.config.stripe_config }

    before { allow(Rails.application.config).to receive(:stripe_config).and_return(config.merge(trial_days: 60)) }

    def history(*statuses)
      ::Stripe::ListObject.construct_from(
        object: 'list',
        data: statuses.each_with_index.map { |st, i| { id: "sub_h#{i}", object: 'subscription', status: st } }
      )
    end

    it 'gives a new restaurant the full trial without asking Stripe' do
      expect(::Stripe::Subscription).not_to receive(:list)
      expect(org.checkout_trial_days).to eq(60)
    end

    # Carmin: a comp org switching to paid (Alfio's) is charged the same day.
    it 'gives a complimentary org no trial' do
      org.grant_complimentary!(by: owner, reason: 'Founding customer')
      expect(org.checkout_trial_days).to eq(0)
    end

    it 'gives a returning customer no second trial' do
      org.update!(stripe_customer_id: 'cus_back')
      allow(::Stripe::Subscription).to receive(:list).and_return(history('canceled'))
      expect(org.checkout_trial_days).to eq(0)
    end

    it 'ignores test-mode history (customer unknown under the live key)' do
      org.update!(stripe_customer_id: 'cus_test_era')
      allow(::Stripe::Subscription).to receive(:list).and_raise(resource_missing)
      expect(org.checkout_trial_days).to eq(60)
    end

    it 'is zero when trials are turned off' do
      allow(Rails.application.config).to receive(:stripe_config).and_return(config.merge(trial_days: 0))
      expect(org.checkout_trial_days).to eq(0)
    end
  end

  describe '#live_stripe_subscription' do
    def stripe_list(*statuses)
      ::Stripe::ListObject.construct_from(
        object: 'list',
        data: statuses.each_with_index.map { |st, i| { id: "sub_#{i}", object: 'subscription', status: st } }
      )
    end

    before { org.update!(stripe_customer_id: 'cus_list') }

    it 'returns a live subscription Stripe knows about' do
      allow(::Stripe::Subscription).to receive(:list).and_return(stripe_list('canceled', 'past_due'))
      expect(org.live_stripe_subscription&.status).to eq('past_due')
    end

    it 'ignores canceled and abandoned (incomplete) subscriptions' do
      allow(::Stripe::Subscription).to receive(:list).and_return(stripe_list('canceled', 'incomplete', 'incomplete_expired'))
      expect(org.live_stripe_subscription).to be_nil
    end

    it 'is nil when the saved customer is missing in this Stripe mode' do
      allow(::Stripe::Subscription).to receive(:list).and_raise(resource_missing)
      expect(org.live_stripe_subscription).to be_nil
    end

    it 'is nil without a Stripe customer' do
      org.update!(stripe_customer_id: nil)
      expect(org.live_stripe_subscription).to be_nil
    end
  end
end
