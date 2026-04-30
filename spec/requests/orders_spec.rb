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

    # Regression: a price_changed (or any other actionable) order with no batch
    # sibling used to be invisible on the index — only completed orders, drafts,
    # and batch siblings of those were rendered. The dashboard surfaced it but
    # Order History did not, so chefs had no way to delete it.
    it 'shows orphan price_changed orders that have no batch sibling' do
      orphan = create(:order,
        user: user, supplier: supplier, organization: org, location: location,
        status: 'price_changed', batch_id: nil)
      create(:order_item, order: orphan, supplier_product: supplier_product)

      get orders_path
      expect(response.body).to include("Order ##{orphan.id}")
    end

    it 'shows orphan failed orders that have no batch sibling' do
      orphan = create(:order, :failed,
        user: user, supplier: supplier, organization: org, location: location,
        batch_id: nil)
      create(:order_item, order: orphan, supplier_product: supplier_product)

      get orders_path
      expect(response.body).to include("Order ##{orphan.id}")
    end

    context 'with status filter' do
      let!(:completed) do
        create(:order, :submitted,
          user: user, supplier: supplier, organization: org, location: location,
          submitted_at: 2.days.ago).tap do |o|
            create(:order_item, order: o, supplier_product: supplier_product)
          end
      end

      let!(:draft) do
        create(:order, :draft,
          user: user, supplier: supplier, organization: org, location: location).tap do |o|
            create(:order_item, order: o, supplier_product: supplier_product)
          end
      end

      let!(:price_changed) do
        create(:order,
          user: user, supplier: supplier, organization: org, location: location,
          status: 'price_changed').tap do |o|
            create(:order_item, order: o, supplier_product: supplier_product)
          end
      end

      let!(:cancelled) do
        create(:order,
          user: user, supplier: supplier, organization: org, location: location,
          status: 'cancelled').tap do |o|
            create(:order_item, order: o, supplier_product: supplier_product)
          end
      end

      it 'status=drafts shows only drafts' do
        get orders_path, params: { status: 'drafts' }
        expect(response.body).to include("Order ##{draft.id}")
        expect(response.body).not_to include("Order ##{completed.id}")
        expect(response.body).not_to include("Order ##{price_changed.id}")
        expect(response.body).not_to include("Order ##{cancelled.id}")
      end

      it 'status=active shows price_changed/pending but not drafts or completed' do
        get orders_path, params: { status: 'active' }
        expect(response.body).to include("Order ##{price_changed.id}")
        expect(response.body).not_to include("Order ##{draft.id}")
        expect(response.body).not_to include("Order ##{completed.id}")
        expect(response.body).not_to include("Order ##{cancelled.id}")
      end

      it 'status=cancelled surfaces cancelled orders that the default view hides' do
        get orders_path
        expect(response.body).not_to include("Order ##{cancelled.id}")

        get orders_path, params: { status: 'cancelled' }
        expect(response.body).to include("Order ##{cancelled.id}")
      end

      it 'status=completed honors the date range' do
        get orders_path, params: { status: 'completed', date_from: 1.day.ago.to_date, date_to: Date.current }
        expect(response.body).not_to include("Order ##{completed.id}")

        get orders_path, params: { status: 'completed', date_from: 7.days.ago.to_date, date_to: Date.current }
        expect(response.body).to include("Order ##{completed.id}")
      end
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
