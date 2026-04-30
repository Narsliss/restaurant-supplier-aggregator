require 'rails_helper'

RSpec.describe 'Orders', type: :request do
  let(:user) { create(:user, :fully_onboarded) }
  let(:org) { user.current_organization }
  let(:location) { org.locations.first }
  let(:supplier) { create(:supplier) }
  let(:supplier_product) { create(:supplier_product, supplier: supplier, current_price: 10.00) }

  before { sign_in user }

  describe 'GET /orders' do
    it 'returns 200 for an authenticated owner' do
      get orders_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET /orders/:id' do
    let!(:order) do
      create(:order, user: user, supplier: supplier, organization: org, location: location).tap do |o|
        create(:order_item, order: o, supplier_product: supplier_product)
      end
    end

    it 'returns the requested order' do
      get order_path(order)
      expect(response).to have_http_status(:ok)
    end

    it 'is not accessible for an order in another organization' do
      other_user = create(:user, :fully_onboarded)
      other_org = other_user.current_organization
      foreign_order = create(:order, user: other_user, supplier: supplier, organization: other_org)

      get order_path(foreign_order)
      expect(response.status).not_to eq(200) # 302 redirect or 404 — the org scope must reject
    end
  end

  describe 'POST /orders/:id/submit' do
    let!(:order) do
      create(:order, user: user, supplier: supplier, organization: org, location: location, status: 'pending').tap do |o|
        create(:order_item, order: o, supplier_product: supplier_product)
      end
    end

    it 'enqueues PlaceOrderJob and sets status=processing' do
      expect {
        post submit_order_path(order)
      }.to have_enqueued_job(PlaceOrderJob).with(order.id, hash_including(accept_price_changes: false, skip_warnings: false))

      expect(order.reload.status).to eq('processing')
    end

    it 'forwards accept_price_changes and skip_warnings params' do
      expect {
        post submit_order_path(order), params: { accept_price_changes: 'true', skip_warnings: 'true' }
      }.to have_enqueued_job(PlaceOrderJob).with(order.id, hash_including(accept_price_changes: true, skip_warnings: true))
    end

    it 'does NOT enqueue when the order is already submitted (idempotency at controller layer)' do
      order.update!(status: 'submitted', submitted_at: Time.current)

      expect {
        post submit_order_path(order)
      }.not_to have_enqueued_job(PlaceOrderJob)
    end
  end

  describe 'POST /orders/:id/cancel' do
    let!(:order) do
      create(:order, user: user, supplier: supplier, organization: org, location: location, status: 'pending')
    end

    it 'transitions the order to cancelled when can_cancel?' do
      post cancel_order_path(order)
      expect(order.reload.status).to eq('cancelled')
    end

    it 'is a no-op when order is already submitted' do
      order.update!(status: 'submitted', submitted_at: Time.current)
      post cancel_order_path(order)
      expect(order.reload.status).to eq('submitted')
    end
  end
end
