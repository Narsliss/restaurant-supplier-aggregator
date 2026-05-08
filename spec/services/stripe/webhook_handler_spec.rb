require 'rails_helper'

RSpec.describe Stripe::WebhookHandler, type: :service do
  # Helper: build a Stripe::Event from a hash. Wraps with the same construction
  # path Stripe::Webhook.construct_event uses, so nested objects come back as
  # Stripe::StripeObject (not Hash) — which is the substrate of the original bug.
  def stripe_event(type:, data_object:, id: nil)
    ::Stripe::Event.construct_from(
      id: id || "evt_#{SecureRandom.hex(8)}",
      object: 'event',
      type: type,
      api_version: '2026-02-25.clover',
      created: Time.current.to_i,
      livemode: false,
      pending_webhooks: 1,
      data: { object: data_object }
    )
  end

  # ---------------------------------------------------------------------------
  # Idempotency / record-first
  # ---------------------------------------------------------------------------
  describe '.handle (idempotency + record-first)' do
    let(:event) do
      stripe_event(
        type: 'customer.created',
        data_object: { id: 'cus_test', object: 'customer', email: 'noone@example.com', metadata: {} }
      )
    end

    it 'creates a BillingEvent on first call, even if no handler match' do
      expect { described_class.handle(event) }.to change(BillingEvent, :count).by(1)
      ev = BillingEvent.find_by!(stripe_event_id: event.id)
      expect(ev.event_type).to eq('customer.created')
    end

    it 'returns :already_processed on a duplicate delivery once marked processed' do
      described_class.handle(event)
      BillingEvent.find_by!(stripe_event_id: event.id).update!(processed: true)

      expect(described_class.handle(event)).to include(status: :already_processed)
    end

    it 'survives a concurrent duplicate (RecordNotUnique gets caught)' do
      BillingEvent.create!(stripe_event_id: event.id, event_type: event.type, data: {}, processed: false)

      expect { described_class.handle(event) }.not_to raise_error
      expect(BillingEvent.where(stripe_event_id: event.id).count).to eq(1)
    end

    it 'records error_message on the BillingEvent when a handler raises' do
      raising_event = stripe_event(
        type: 'customer.subscription.deleted',
        data_object: { id: 'sub_x', object: 'subscription' }
      )

      allow(::Subscription).to receive(:find_by).and_raise(StandardError, 'boom')

      result = described_class.handle(raising_event)
      expect(result[:status]).to eq(:error)

      ev = BillingEvent.find_by!(stripe_event_id: raising_event.id)
      expect(ev.error_message).to eq('boom')
      expect(ev.processed).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Regression: find_user_from_metadata used to crash on Stripe::StripeObject
  # without a user_id key (NoMethodError via method_missing).
  # ---------------------------------------------------------------------------
  describe 'metadata accessor (regression for the original bug)' do
    it 'does not raise when metadata is an empty StripeObject' do
      event = stripe_event(
        type: 'customer.created',
        data_object: {
          id: 'cus_empty',
          object: 'customer',
          email: 'nobody@example.com',
          metadata: {} # empty StripeObject — used to crash on .user_id
        }
      )

      expect { described_class.handle(event) }.not_to raise_error
      expect(described_class.handle(event)[:status]).not_to eq(:error)
    end

    it 'does not raise on customer.subscription.created with empty metadata' do
      event = stripe_event(
        type: 'customer.subscription.created',
        data_object: {
          id: 'sub_empty',
          object: 'subscription',
          status: 'active',
          customer: 'cus_unknown',
          metadata: {},
          items: { data: [{ id: 'si_1', price: { id: 'price_1' }, current_period_start: 1.day.ago.to_i, current_period_end: 29.days.from_now.to_i }] }
        }
      )

      expect { described_class.handle(event) }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # Customer.created — write to Organization (canonical), not User
  # ---------------------------------------------------------------------------
  describe '#handle_customer_created' do
    let(:user) { create(:user, :with_organization) }
    let(:org) { user.current_organization }

    it 'sets organization.stripe_customer_id when metadata.organization_id is present' do
      event = stripe_event(
        type: 'customer.created',
        data_object: {
          id: 'cus_abc',
          object: 'customer',
          email: user.email,
          metadata: { organization_id: org.id }
        }
      )

      expect { described_class.handle(event) }
        .to change { org.reload.stripe_customer_id }.from(nil).to('cus_abc')
    end

    it 'does not overwrite an already-set stripe_customer_id' do
      org.update!(stripe_customer_id: 'cus_existing')

      event = stripe_event(
        type: 'customer.created',
        data_object: {
          id: 'cus_new',
          object: 'customer',
          email: user.email,
          metadata: { organization_id: org.id }
        }
      )

      described_class.handle(event)
      expect(org.reload.stripe_customer_id).to eq('cus_existing')
    end
  end

  # ---------------------------------------------------------------------------
  # Subscription handlers
  # ---------------------------------------------------------------------------
  describe '#handle_subscription_created' do
    let(:user) { create(:user, :with_organization) }
    let(:org) { user.current_organization }

    let(:subscription_data) do
      {
        id: 'sub_test_1',
        object: 'subscription',
        status: 'active',
        customer: 'cus_test_1',
        cancel_at_period_end: false,
        canceled_at: nil,
        ended_at: nil,
        trial_start: nil,
        trial_end: nil,
        metadata: { user_id: user.id, organization_id: org.id },
        items: {
          data: [{
            id: 'si_1',
            price: { id: 'price_test' },
            current_period_start: 1.day.ago.to_i,
            current_period_end: 29.days.from_now.to_i
          }]
        }
      }
    end

    it 'creates a Subscription row and attributes the BillingEvent' do
      event = stripe_event(type: 'customer.subscription.created', data_object: subscription_data)

      expect { described_class.handle(event) }.to change(Subscription, :count).by(1)

      sub = Subscription.find_by(stripe_subscription_id: 'sub_test_1')
      expect(sub.user).to eq(user)
      expect(sub.status).to eq('active')

      ev = BillingEvent.find_by!(stripe_event_id: event.id)
      expect(ev.user_id).to eq(user.id)
      expect(ev.subscription_id).to eq(sub.id)
      expect(ev.processed).to be true
    end

    it 'returns :user_not_found and does NOT mark processed when no user can be resolved' do
      orphan_data = subscription_data.merge(metadata: {}, customer: 'cus_unknown')
      event = stripe_event(type: 'customer.subscription.created', data_object: orphan_data)

      result = described_class.handle(event)
      expect(result[:status]).to eq(:user_not_found)

      ev = BillingEvent.find_by!(stripe_event_id: event.id)
      expect(ev.processed).to be false
      expect(ev.error_message).to be_nil
    end
  end

  describe '#handle_subscription_paused / .resumed' do
    let(:user) { create(:user, :with_organization) }
    let!(:sub) { create(:subscription, user: user, stripe_subscription_id: 'sub_pause') }

    it 'syncs the new status when paused' do
      paused_data = {
        id: 'sub_pause', object: 'subscription', status: 'paused',
        customer: 'cus_x', cancel_at_period_end: false,
        canceled_at: nil, ended_at: nil, trial_start: nil, trial_end: nil,
        metadata: {},
        items: { data: [{ id: 'si_x', price: { id: 'price_test' },
                          current_period_start: 1.day.ago.to_i,
                          current_period_end: 29.days.from_now.to_i }] }
      }
      event = stripe_event(type: 'customer.subscription.paused', data_object: paused_data)

      described_class.handle(event)
      expect(sub.reload.status).to eq('paused')
    end

    it 'syncs the new status when resumed' do
      resumed_data = {
        id: 'sub_pause', object: 'subscription', status: 'active',
        customer: 'cus_x', cancel_at_period_end: false,
        canceled_at: nil, ended_at: nil, trial_start: nil, trial_end: nil,
        metadata: {},
        items: { data: [{ id: 'si_x', price: { id: 'price_test' },
                          current_period_start: 1.day.ago.to_i,
                          current_period_end: 29.days.from_now.to_i }] }
      }
      sub.update!(status: 'paused')
      event = stripe_event(type: 'customer.subscription.resumed', data_object: resumed_data)

      described_class.handle(event)
      expect(sub.reload.status).to eq('active')
    end
  end

  # ---------------------------------------------------------------------------
  # Invoice handlers
  # ---------------------------------------------------------------------------
  describe '#handle_invoice_payment_action_required' do
    let(:user) { create(:user, :with_organization) }
    let(:org) { user.current_organization }
    let!(:sub) { create(:subscription, user: user) }

    it 'records the invoice and queues the action-required mailer' do
      org.update!(stripe_customer_id: 'cus_action')

      invoice_data = {
        id: 'in_action_1', object: 'invoice', customer: 'cus_action',
        status: 'open', amount_due: 9900, amount_paid: 0, currency: 'usd',
        hosted_invoice_url: 'https://invoice.example/auth',
        invoice_pdf: nil, period_start: 1.day.ago.to_i, period_end: 29.days.from_now.to_i,
        subscription: sub.stripe_subscription_id,
        status_transitions: { paid_at: nil }
      }
      event = stripe_event(type: 'invoice.payment_action_required', data_object: invoice_data)

      expect {
        expect { described_class.handle(event) }.to change(Invoice, :count).by(1)
      }.to have_enqueued_mail(BillingMailer, :payment_action_required)
    end
  end

  # ---------------------------------------------------------------------------
  # Unhandled event type
  # ---------------------------------------------------------------------------
  describe 'unhandled event types' do
    it 'records the BillingEvent and returns :ignored' do
      event = stripe_event(type: 'something.weird', data_object: { id: 'x' })

      result = described_class.handle(event)
      expect(result[:status]).to eq(:ignored)
      expect(BillingEvent.find_by(stripe_event_id: event.id)).to be_present
    end
  end
end
