require 'rails_helper'

RSpec.describe 'Subscriptions', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }

  before { sign_in owner }

  describe 'GET /subscription' do
    it 'returns 200' do
      get subscription_path
      expect(response).to have_http_status(:ok)
    end
  end

  # Regression: the Cancel Subscription button previously used data-confirm, which
  # rails-ujs honors but Turbo ignores. This app loads only Turbo (no rails-ujs in
  # the importmap), so data-confirm rendered NO confirmation dialog — a chef could
  # cancel with one click. Turbo requires data-turbo-confirm.
  describe 'GET /subscription cancel button confirmation' do
    it 'renders a Turbo-compatible data-turbo-confirm guard, not the dead data-confirm' do
      create(:subscription, user: owner) # active, cancel_at_period_end: false

      get subscription_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Cancel Subscription')
      expect(response.body).to match(/data-turbo-confirm="Are you sure you want to cancel/)
      expect(response.body).not_to match(/data-confirm="Are you sure you want to cancel/)
    end
  end

  describe 'GET /subscription/new' do
    it 'returns 200 (or redirects for already-subscribed users)' do
      get new_subscription_path
      expect(response).to have_http_status(:ok).or be_redirect
    end
  end

  describe 'GET /subscription/success' do
    it 'returns 200' do
      get success_subscription_path
      expect(response).to have_http_status(:ok).or be_redirect
    end
  end

  describe 'auth gate' do
    it 'redirects unauthenticated to sign in' do
      sign_out owner
      get subscription_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'manager (non-owner) gate on billing actions' do
    it 'redirects manager away from billing_portal' do
      manager = create(:user)
      create(:membership, user: manager, organization: org, role: 'manager', active: true)
      manager.update!(current_organization: org)

      sign_out owner
      sign_in manager
      post billing_portal_subscription_path
      expect(response).to be_redirect
      expect(response.location).not_to include('stripe.com')
    end
  end
end

RSpec.describe 'Stripe webhooks', type: :request do
  let(:headers) { { 'CONTENT_TYPE' => 'application/json' } }

  describe 'POST /webhooks/stripe' do
    it 'rejects requests without a webhook secret configured' do
      allow(Rails.application.config).to receive(:stripe_webhook_secret).and_return(nil)

      post '/webhooks/stripe', params: '{}', headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it 'rejects requests with an invalid Stripe signature' do
      allow(Rails.application.config).to receive(:stripe_webhook_secret).and_return('whsec_test')

      post '/webhooks/stripe', params: '{"id":"evt_1"}', headers: headers.merge('HTTP_STRIPE_SIGNATURE' => 'invalid')
      expect(response).to have_http_status(:bad_request)
    end

    it 'returns 400 on malformed JSON payload' do
      allow(Rails.application.config).to receive(:stripe_webhook_secret).and_return('whsec_test')
      # Force JSON::ParserError before signature check by stubbing construct_event
      allow(Stripe::Webhook).to receive(:construct_event).and_raise(JSON::ParserError, 'bad json')

      post '/webhooks/stripe', params: 'not-json', headers: headers.merge('HTTP_STRIPE_SIGNATURE' => 'sig')
      expect(response).to have_http_status(:bad_request)
    end

    it 'does NOT require authentication (it skips authenticate_user!)' do
      allow(Rails.application.config).to receive(:stripe_webhook_secret).and_return(nil)

      post '/webhooks/stripe', params: '{}', headers: headers
      # Returns 403 (no secret), NOT a redirect to login
      expect(response).not_to redirect_to(new_user_session_path)
    end

    it 'returns 200 (not 422) when the handler raises, so Stripe stops retrying' do
      allow(Rails.application.config).to receive(:stripe_webhook_secret).and_return('whsec_test')

      fake_event = ::Stripe::Event.construct_from(
        id: 'evt_handler_crash', object: 'event', type: 'customer.created',
        data: { object: { id: 'cus_x', object: 'customer', email: 'x@e.com', metadata: {} } }
      )
      allow(::Stripe::Webhook).to receive(:construct_event).and_return(fake_event)
      allow(::Stripe::WebhookHandler).to receive(:handle).and_return(status: :error, message: 'kaboom')

      post '/webhooks/stripe', params: '{}', headers: headers.merge('HTTP_STRIPE_SIGNATURE' => 'sig')
      expect(response).to have_http_status(:ok)
    end

    it 'returns 200 on :user_not_found / :subscription_not_found' do
      allow(Rails.application.config).to receive(:stripe_webhook_secret).and_return('whsec_test')

      fake_event = ::Stripe::Event.construct_from(
        id: 'evt_user_missing', object: 'event', type: 'customer.subscription.created',
        data: { object: { id: 'sub_x', object: 'subscription' } }
      )
      allow(::Stripe::Webhook).to receive(:construct_event).and_return(fake_event)
      allow(::Stripe::WebhookHandler).to receive(:handle).and_return(status: :user_not_found)

      post '/webhooks/stripe', params: '{}', headers: headers.merge('HTTP_STRIPE_SIGNATURE' => 'sig')
      expect(response).to have_http_status(:ok)
    end
  end
end
