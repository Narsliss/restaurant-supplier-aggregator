require 'rails_helper'

RSpec.describe Subscription, type: :model do
  describe 'validations' do
    it 'requires stripe_subscription_id and status' do
      sub = build(:subscription, stripe_subscription_id: nil, status: nil)
      expect(sub).not_to be_valid
      expect(sub.errors[:stripe_subscription_id]).to be_present
      expect(sub.errors[:status]).to be_present
    end

    it 'enforces unique stripe_subscription_id' do
      existing = create(:subscription)
      duplicate = build(:subscription, stripe_subscription_id: existing.stripe_subscription_id)
      expect(duplicate).not_to be_valid
    end

    it 'rejects unknown status values' do
      sub = build(:subscription, status: 'wat')
      expect(sub).not_to be_valid
    end
  end

  describe '#allows_access?' do
    it 'is true for active, trialing, past_due' do
      expect(build(:subscription, status: 'active').allows_access?).to be true
      expect(build(:subscription, :trialing).allows_access?).to be true
      expect(build(:subscription, :past_due).allows_access?).to be true
    end

    it 'is false for canceled, unpaid, paused, incomplete' do
      %w[canceled unpaid paused incomplete incomplete_expired].each do |status|
        expect(build(:subscription, status: status).allows_access?).to be(false), "expected #{status} to not allow access"
      end
    end
  end

  describe '#canceled_but_active?' do
    it 'is true when cancel_at_period_end is set and current_period_end is in the future' do
      sub = build(:subscription, :cancel_at_period_end, current_period_end: 7.days.from_now)
      expect(sub.canceled_but_active?).to be true
    end

    it 'is false once the period has ended' do
      sub = build(:subscription, :cancel_at_period_end, current_period_end: 1.day.ago)
      expect(sub.canceled_but_active?).to be false
    end
  end

  describe '#days_remaining' do
    it 'returns days from now until current_period_end' do
      sub = build(:subscription, current_period_end: 10.days.from_now)
      expect(sub.days_remaining).to be_between(9, 10)
    end

    it 'clamps at 0 when the period is past' do
      sub = build(:subscription, current_period_end: 5.days.ago)
      expect(sub.days_remaining).to eq(0)
    end
  end

  describe '#trial_days_remaining' do
    it 'returns 0 when not trialing' do
      sub = build(:subscription, status: 'active', trial_end: 10.days.from_now)
      expect(sub.trial_days_remaining).to eq(0)
    end

    it 'returns days until trial_end when trialing' do
      sub = build(:subscription, :trialing, trial_end: 7.days.from_now)
      expect(sub.trial_days_remaining).to be_between(6, 7)
    end
  end

  describe '#formatted_amount' do
    it 'formats cents as a dollar string with interval suffix' do
      sub = build(:subscription, amount_cents: 2900, interval: 'month')
      expect(sub.formatted_amount).to eq('$29.00/month')
    end
  end

  describe '.sync_from_stripe (period field migration)' do
    let(:user) { create(:user, :with_organization) }

    def fake_stripe_subscription(period_at_item_level:, period_at_top_level:)
      item = ::Stripe::SubscriptionItem.construct_from(
        id: 'si_1',
        price: { id: 'price_test' },
        current_period_start: period_at_item_level&.first,
        current_period_end: period_at_item_level&.last
      )

      attrs = {
        id: 'sub_period_test',
        object: 'subscription',
        status: 'active',
        customer: 'cus_x',
        cancel_at_period_end: false,
        canceled_at: nil,
        ended_at: nil,
        trial_start: nil,
        trial_end: nil,
        metadata: { user_id: user.id },
        items: { data: [item] }
      }
      attrs[:current_period_start] = period_at_top_level&.first if period_at_top_level
      attrs[:current_period_end] = period_at_top_level&.last if period_at_top_level

      ::Stripe::Subscription.construct_from(attrs)
    end

    it 'reads period fields from the subscription item (new API >= 2025-04)' do
      starts = 1.day.ago.to_i
      ends = 29.days.from_now.to_i
      stripe_sub = fake_stripe_subscription(period_at_item_level: [starts, ends], period_at_top_level: nil)

      sub = described_class.sync_from_stripe(stripe_sub, user: user)
      expect(sub.current_period_start.to_i).to eq(starts)
      expect(sub.current_period_end.to_i).to eq(ends)
    end

    it 'falls back to top-level period fields when item-level is missing (old API)' do
      starts = 2.days.ago.to_i
      ends = 28.days.from_now.to_i
      stripe_sub = fake_stripe_subscription(period_at_item_level: nil, period_at_top_level: [starts, ends])

      sub = described_class.sync_from_stripe(stripe_sub, user: user)
      expect(sub.current_period_start.to_i).to eq(starts)
      expect(sub.current_period_end.to_i).to eq(ends)
    end

    it 'leaves periods nil (does NOT raise TypeError) when neither is present' do
      stripe_sub = fake_stripe_subscription(period_at_item_level: nil, period_at_top_level: nil)

      expect { described_class.sync_from_stripe(stripe_sub, user: user) }.not_to raise_error
      sub = Subscription.find_by!(stripe_subscription_id: 'sub_period_test')
      expect(sub.current_period_start).to be_nil
      expect(sub.current_period_end).to be_nil
    end
  end

  describe 'scopes' do
    let!(:active) { create(:subscription, status: 'active') }
    let!(:trialing) { create(:subscription, :trialing) }
    let!(:past_due) { create(:subscription, :past_due) }
    let!(:canceled) { create(:subscription, :canceled) }

    it '.active_or_trialing returns active and trialing only' do
      expect(Subscription.active_or_trialing).to contain_exactly(active, trialing)
    end

    it '.past_due returns only past_due' do
      expect(Subscription.past_due).to contain_exactly(past_due)
    end

    it '.canceled returns only canceled' do
      expect(Subscription.canceled).to contain_exactly(canceled)
    end
  end
end
