require 'rails_helper'

RSpec.describe Invoice, type: :model do
  describe '.sync_from_stripe' do
    let(:owner) { create(:user, :with_organization) }
    let(:org) { owner.current_organization }
    let!(:sub) { create(:subscription, user: owner, organization_id: org.id, stripe_subscription_id: 'sub_inv') }

    def stripe_invoice(**attrs)
      ::Stripe::Invoice.construct_from({
        id: 'in_1', object: 'invoice', customer: 'cus_inv', status: 'paid',
        amount_due: 12_900, amount_paid: 12_900, currency: 'usd',
        hosted_invoice_url: nil, invoice_pdf: nil,
        period_start: 1.day.ago.to_i, period_end: 29.days.from_now.to_i,
        status_transitions: { paid_at: Time.current.to_i }
      }.merge(attrs))
    end

    def clover_parent(subscription_id)
      { type: 'subscription_details', subscription_details: { subscription: subscription_id, metadata: {} } }
    end

    # Regression: API 2025-03-31.basil moved invoice.subscription under
    # parent.subscription_details. Every prod invoice was unlinked, so the
    # payment-failed and 3D Secure emails (guarded on invoice.subscription)
    # never sent.
    it 'links the subscription from a clover-shaped payload (parent.subscription_details)' do
      invoice = described_class.sync_from_stripe(stripe_invoice(parent: clover_parent('sub_inv')))

      expect(invoice.subscription).to eq(sub)
      expect(invoice.user).to eq(owner)
      expect(invoice.organization_id).to eq(org.id)
    end

    it 'still reads the legacy top-level subscription field' do
      invoice = described_class.sync_from_stripe(stripe_invoice(subscription: 'sub_inv'))
      expect(invoice.subscription).to eq(sub)
    end

    # Regression: invoices whose customer didn't match the org's saved
    # customer failed with "User must exist" (12 prod events by Oct 2026).
    it 'resolves the owner through the subscription when the customer matches no org' do
      org.update!(stripe_customer_id: 'cus_something_else')

      invoice = described_class.sync_from_stripe(stripe_invoice(customer: 'cus_unknown', parent: clover_parent('sub_inv')))
      expect(invoice).to be_persisted
      expect(invoice.user).to eq(owner)
    end

    it 'resolves by customer when there is no subscription reference' do
      org.update!(stripe_customer_id: 'cus_inv')

      invoice = described_class.sync_from_stripe(stripe_invoice(parent: nil))
      expect(invoice.user).to eq(owner)
      expect(invoice.subscription).to be_nil
    end

    it 'returns nil and saves nothing when nothing matches' do
      result = nil
      expect {
        result = described_class.sync_from_stripe(stripe_invoice(customer: 'cus_stranger', parent: clover_parent('sub_stranger')))
      }.not_to change(described_class, :count)
      expect(result).to be_nil
    end
  end
end
