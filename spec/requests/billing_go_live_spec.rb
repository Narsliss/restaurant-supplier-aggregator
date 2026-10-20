require 'rails_helper'

# Behaviour required before Stripe live mode (docs/stripe-go-live.md).
RSpec.describe 'Billing go-live', type: :request do
  let(:owner) { create(:user, :fully_onboarded) } # comp org
  let(:org) { owner.current_organization }
  let(:base_config) { Rails.application.config.stripe_config }

  def configure_prices!
    config = base_config.merge(monthly_price_id: 'price_base', seat_price_id: 'price_seat')
    allow(Rails.application.config).to receive(:stripe_config).and_return(config)
  end

  def add_chefs(count)
    count.times { create(:membership, organization: org, user: create(:user), role: 'chef', active: true) }
  end

  before { sign_in owner }

  describe 'past-due restaurant' do
    before do
      org.update_columns(complimentary: false)
      create(:subscription, :past_due, user: owner, organization_id: org.id)
    end

    it 'keeps access to gated pages while Stripe retries the card' do
      get orders_path
      expect(response).not_to redirect_to(new_subscription_path)
    end

    # Regression: the banner called a route helper that doesn't exist; it never
    # rendered only because past_due subscriptions were invisible.
    it 'shows the owner the payment-failed bar with a working billing-portal button' do
      get subscription_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-payment-failed-bar')
      expect(response.body).to include('action="/subscription/billing_portal"')
    end

    it 'does not show the bar to non-owners' do
      manager = org.memberships.find_by(role: 'manager').user
      manager.update!(current_organization: org)
      sign_out owner
      sign_in manager

      get subscription_path
      expect(response.body).not_to include('data-payment-failed-bar')
    end

    it 'refuses a second Checkout' do
      expect(::Stripe::Checkout::Session).not_to receive(:create)

      post subscription_path
      expect(response).to redirect_to(subscription_path)
      expect(flash[:alert]).to include('already have a subscription')
    end
  end

  describe 'Checkout when only Stripe knows about a live subscription' do
    before do
      org.update_columns(complimentary: false, stripe_customer_id: 'cus_known')
    end

    it 'syncs it and refuses a second Checkout' do
      live = ::Stripe::Subscription.construct_from(
        id: 'sub_missed_webhook', object: 'subscription', status: 'active', customer: 'cus_known',
        cancel_at_period_end: false, canceled_at: nil, ended_at: nil, trial_start: nil, trial_end: nil,
        metadata: { organization_id: org.id.to_s },
        items: { data: [{ id: 'si_1', price: { id: 'price_base' },
                          current_period_start: 1.day.ago.to_i, current_period_end: 29.days.from_now.to_i }] }
      )
      allow(::Stripe::Subscription).to receive(:list)
        .and_return(::Stripe::ListObject.construct_from(object: 'list', data: [live]))
      expect(::Stripe::Checkout::Session).not_to receive(:create)

      post subscription_path
      expect(response).to redirect_to(subscription_path)
      expect(org.subscriptions.find_by(stripe_subscription_id: 'sub_missed_webhook')).to be_present
    end
  end

  describe 'complimentary restaurant switching to paid' do
    # Regression: /subscription/new redirected comp orgs to /subscription,
    # which linked back to /subscription/new, a loop.
    it 'shows the pricing page with the complimentary notice' do
      get new_subscription_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-complimentary-notice')
    end

    it 'shows "Switch to paid" on the subscription page' do
      get subscription_path
      expect(response.body).to include('data-complimentary-plan')
      expect(response.body).to include('Switch to paid')
    end

    it 'shows the full monthly total including extra seats' do
      configure_prices!
      add_chefs(7) # 1 manager + 7 chefs = 8 seats, 3 over the included 5

      get new_subscription_path
      expect(response.body).to include('Total: $129/month')
    end

    it 'opens Checkout with the base plan and the extra seats' do
      configure_prices!
      add_chefs(7)
      allow(::Stripe::Customer).to receive(:create)
        .and_return(::Stripe::Customer.construct_from(id: 'cus_new', object: 'customer'))
      expect(::Stripe::Checkout::Session).to receive(:create) do |params|
        expect(params[:line_items]).to contain_exactly(
          { price: 'price_base', quantity: 1 },
          { price: 'price_seat', quantity: 3 }
        )
        ::Stripe::Checkout::Session.construct_from(id: 'cs_1', url: 'https://checkout.stripe.com/c/pay/cs_1')
      end

      post subscription_path
      expect(response.body).to include('https://checkout.stripe.com/c/pay/cs_1')
    end
  end

  describe 'support contact' do
    it 'shows the support inbox on the Subscription page and the Terms' do
      get subscription_path
      expect(response.body).to include('mailto:carmin@las-noches.com')

      get terms_path
      expect(response.body).to include('mailto:carmin@las-noches.com')
    end

    # Regression: the old product name's addresses (support@supplierhub.com /
    # .app) were dead inboxes on the pages paying customers read.
    it 'leaves no old-brand support address in any view' do
      offenders = Dir[Rails.root.join('app/views/**/*.erb')].select { |f| File.read(f).include?('@supplierhub.') }
      expect(offenders).to be_empty
    end
  end

  describe 'POST /subscription/reactivate' do
    it 'ignores an old canceled row that still carries cancel_at_period_end' do
      org.update_columns(complimentary: false)
      create(:subscription, :canceled, :cancel_at_period_end, user: owner, organization_id: org.id)
      create(:subscription, user: owner, organization_id: org.id) # live, not canceling
      expect(::Stripe::Subscription).not_to receive(:update)

      post reactivate_subscription_path
      expect(response).to redirect_to(subscription_path)
    end
  end

  describe 'admin extend trial' do
    let(:super_admin) { create(:user, :super_admin) }

    # Regression: days were added to the old trial_end, so extending a trial
    # that ended a month ago produced a past date that Stripe rejects.
    it 'extends from today when the old trial already ended' do
      sub = create(:subscription, user: owner, organization_id: org.id, trial_end: 30.days.ago)
      sign_out owner
      sign_in super_admin

      expect(::Stripe::Subscription).to receive(:update) do |id, params|
        expect(id).to eq(sub.stripe_subscription_id)
        expect(Time.zone.at(params[:trial_end])).to be_within(1.minute).of(14.days.from_now)
      end

      post "/admin/organizations/#{org.id}/extend_trial", params: { days: 14 }
    end
  end
end
