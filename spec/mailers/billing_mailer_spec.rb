require 'rails_helper'

RSpec.describe BillingMailer, type: :mailer do
  let(:organization) { create(:organization, name: 'Test Bistro') }
  let(:owner) { create(:user, first_name: 'Pat', last_name: 'Owner', email: 'pat@example.com') }
  let!(:membership) { create(:membership, user: owner, organization: organization, role: 'owner') }
  let(:subscription) { create(:subscription, user: owner, organization_id: organization.id) }

  before { owner.update!(current_organization: organization) }

  # Regression: Subscription had no `belongs_to :organization`, so every mailer
  # method that called `subscription.organization || subscription.user&.current_organization`
  # raised NoMethodError before reaching `mail()`. Confirmed via Rails runner.
  describe 'subscription.organization association' do
    it 'resolves the organization without raising' do
      expect(subscription.organization).to eq(organization)
    end
  end

  # The emails say "just reply"; from is noreply@, so replies need a reply-to.
  describe 'reply-to' do
    it 'sends replies to the support inbox' do
      mail = described_class.welcome(subscription)
      expect(mail.reply_to).to eq([Rails.configuration.x.support_email])
      expect(mail.reply_to).to eq(['carmin@las-noches.com'])
    end
  end

  describe '#welcome' do
    it 'renders without raising and addresses the org owner' do
      mail = described_class.welcome(subscription)
      expect { mail.body }.not_to raise_error
      expect(mail.to).to eq([owner.email])
      expect(mail.body.to_s).to include('Test Bistro')
    end
  end

  describe '#trial_ending_soon' do
    let(:trialing) { create(:subscription, :trialing, user: owner, organization_id: organization.id) }

    it 'renders without raising' do
      mail = described_class.trial_ending_soon(trialing)
      expect { mail.body }.not_to raise_error
      expect(mail.to).to eq([owner.email])
    end

    it 'states the subscription\'s real monthly amount, not a hardcoded $99' do
      trialing.update!(amount_cents: 17_900)
      mail = described_class.trial_ending_soon(trialing)
      expect(mail.body.to_s).to include('charge the card on file $179.00/month')
      expect(mail.body.to_s).to include('Cancel Subscription before then')
      expect(mail.body.to_s).not_to include('$99')
    end
  end

  describe '#subscription_canceled' do
    let(:canceled) { create(:subscription, :canceled, user: owner, organization_id: organization.id) }

    it 'renders without raising' do
      mail = described_class.subscription_canceled(canceled)
      expect { mail.body }.not_to raise_error
      expect(mail.to).to eq([owner.email])
    end

    # Sent on customer.subscription.deleted, i.e. once access has ended.
    it 'says access has ended and links to resubscribe' do
      mail = described_class.subscription_canceled(canceled)
      expect(mail.subject).to eq('Your EnPlace Pro subscription has ended')
      expect(mail.body.to_s).to include('no longer has access')
      expect(mail.body.to_s).to include('/subscription/new')
      expect(mail.body.to_s).not_to include('continue to have access')
    end
  end

  describe '#payment_failed' do
    let(:invoice) do
      Invoice.create!(
        user: owner,
        subscription: subscription,
        stripe_invoice_id: "in_#{SecureRandom.hex(8)}",
        status: 'open',
        amount_due_cents: 2900
      )
    end

    it 'renders without raising' do
      mail = described_class.payment_failed(invoice)
      expect { mail.body }.not_to raise_error
      expect(mail.to).to eq([owner.email])
    end
  end

  describe '#payment_action_required' do
    let(:invoice) do
      Invoice.create!(
        user: owner,
        subscription: subscription,
        stripe_invoice_id: "in_#{SecureRandom.hex(8)}",
        status: 'open',
        amount_due_cents: 2900,
        hosted_invoice_url: 'https://invoice.stripe.com/test'
      )
    end

    it 'renders without raising' do
      mail = described_class.payment_action_required(invoice)
      expect { mail.body }.not_to raise_error
      expect(mail.to).to eq([owner.email])
    end
  end

  describe '#new_paid_signup' do
    let!(:super_admin) { create(:user, :super_admin) }

    it 'sends to the super admin with org context' do
      mail = described_class.new_paid_signup(subscription)

      expect(mail.to).to eq([super_admin.email])
      expect(mail.subject).to include('New signup')
      expect(mail.subject).to include('Test Bistro')

      body = mail.body.to_s
      expect(body).to include('Test Bistro')
      expect(body).to include('pat@example.com')
      expect(body).to include(subscription.stripe_subscription_id)
    end

    it 'is a no-op when no super_admin exists' do
      super_admin.destroy!
      mail = described_class.new_paid_signup(subscription)
      expect(mail.to).to be_nil
    end

    it 'renders for a trialing subscription without raising' do
      trialing = create(:subscription, :trialing, user: owner, organization_id: organization.id)
      mail = described_class.new_paid_signup(trialing)
      expect { mail.body }.not_to raise_error
      expect(mail.body.to_s).to include('trial ends')
    end
  end
end
