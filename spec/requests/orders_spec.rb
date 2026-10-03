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

      it 'status=price_changed shows only price_changed orders' do
        pending_order = create(:order,
          user: user, supplier: supplier, organization: org, location: location,
          status: 'pending').tap { |o| create(:order_item, order: o, supplier_product: supplier_product) }

        get orders_path, params: { status: 'price_changed' }
        expect(response.body).to include("Order ##{price_changed.id}")
        expect(response.body).not_to include("Order ##{pending_order.id}")
        expect(response.body).not_to include("Order ##{draft.id}")
        expect(response.body).not_to include("Order ##{completed.id}")
        expect(response.body).not_to include("Order ##{cancelled.id}")
      end

      it 'status=waiting shows pending/pending_review/pending_manual but not price_changed' do
        pending_order = create(:order,
          user: user, supplier: supplier, organization: org, location: location,
          status: 'pending').tap { |o| create(:order_item, order: o, supplier_product: supplier_product) }

        get orders_path, params: { status: 'waiting' }
        expect(response.body).to include("Order ##{pending_order.id}")
        expect(response.body).not_to include("Order ##{price_changed.id}")
        expect(response.body).not_to include("Order ##{draft.id}")
      end

      it 'status=processing groups verifying with processing' do
        verifying_order = create(:order,
          user: user, supplier: supplier, organization: org, location: location,
          status: 'verifying').tap { |o| create(:order_item, order: o, supplier_product: supplier_product) }
        processing_order = create(:order,
          user: user, supplier: supplier, organization: org, location: location,
          status: 'processing').tap { |o| create(:order_item, order: o, supplier_product: supplier_product) }

        get orders_path, params: { status: 'processing' }
        expect(response.body).to include("Order ##{verifying_order.id}")
        expect(response.body).to include("Order ##{processing_order.id}")
        expect(response.body).not_to include("Order ##{price_changed.id}")
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

    # OrderFailureAlertJob: the chef seeing her failed order in the app means
    # no email. Only her own views count.
    context 'recording that a not-placed order was seen' do
      before { order.update!(status: 'failed', error_message: 'Not placed.') }

      it 'records it when the chef who placed it opens the order' do
        expect(OrderFailureAlertJob).to receive(:mark_seen).with([order])
        get order_path(order)
      end

      it 'records it when her order screen polls the status' do
        expect(OrderFailureAlertJob).to receive(:mark_seen).with([order])
        get placement_status_order_path(order)
      end

      it 'does not count someone else in the organization opening it' do
        teammate = create(:user)
        create(:membership, user: teammate, organization: org, role: 'manager')
        teammate.update!(current_organization: org)
        sign_in teammate

        allow(OrderFailureAlertJob).to receive(:mark_seen)
        get order_path(order)
        expect(OrderFailureAlertJob).not_to have_received(:mark_seen).with([order])
      end

      it 'does not count an admin viewing as the chef' do
        admin = create(:user, :super_admin)
        sign_in admin
        post "/admin/users/#{user.id}/impersonate"

        expect(OrderFailureAlertJob).not_to receive(:mark_seen)
        get order_path(order)
      end
    end

    it 'is not accessible for an order in another organization' do
      other_user = create(:user, :fully_onboarded)
      other_org = other_user.current_organization
      foreign_order = create(:order, user: other_user, supplier: supplier, organization: other_org)

      get order_path(foreign_order)
      expect(response.status).not_to eq(200) # 302 redirect or 404 — the org scope must reject
    end

    context 'supplier exception alert' do
      let(:usf) { Supplier.find_by(code: 'usfoods') || create(:supplier, code: 'usfoods') }
      let(:usf_order) do
        create(:order, user: user, supplier: usf, organization: org, location: location,
                       status: 'submitted', submitted_at: 1.minute.ago, confirmation_number: 'USF-9',
                       supplier_exceptions: [
                         { 'type' => 'out_of_stock', 'sku' => '4572251', 'name' => 'Chuck Tail Flap', 'ordered' => 2, 'filled' => 0, 'message' => 'Out of stock' },
                         { 'type' => 'short_fill', 'sku' => '763300', 'name' => 'Olive Oil', 'ordered' => 10, 'filled' => 6 }
                       ]).tap { |o| create(:order_item, order: o, supplier_product: supplier_product) }
      end

      it 'renders the exception banner with items and a US Foods deep-link' do
        get order_path(usf_order)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('flagged 2 issues')
        expect(response.body).to include('Out of stock')
        expect(response.body).to include('Chuck Tail Flap')
        expect(response.body).to include('order.usfoods.com')
      end

      it 'shows no banner when the order has no exceptions' do
        clean = create(:order, user: user, supplier: usf, organization: org, location: location,
                               status: 'submitted', supplier_exceptions: [])
                .tap { |o| create(:order_item, order: o, supplier_product: supplier_product) }

        get order_path(clean)
        expect(response.body).not_to include('flagged')
      end
    end
  end

  describe 'DELETE /orders/:id' do
    let!(:order) do
      create(:order,
        user: user, supplier: supplier, organization: org, location: location,
        status: 'price_changed').tap do |o|
          create(:order_item, order: o, supplier_product: supplier_product)
        end
    end

    it 'preserves filter params on the redirect so the user lands back on the same view' do
      delete order_path(order), params: { status: 'price_changed', supplier_id: supplier.id }
      expect(response).to redirect_to(orders_path(status: 'price_changed', supplier_id: supplier.id.to_s))
    end

    it 'falls back to plain orders_path when no filter params are present' do
      delete order_path(order)
      expect(response).to redirect_to(orders_path)
    end

    # Regression: the delete form on the index page must put the active filter
    # params into the form action URL so the destroy action can forward them
    # on the redirect. A previous fix only patched the split-row delete button
    # and missed the single-supplier row, dropping the filter on delete.
    it 'renders both delete buttons with current filter params in the form action' do
      get orders_path, params: { status: 'price_changed' }
      expect(response.body).to match(%r{action="/orders/#{order.id}\?[^"]*status=price_changed})
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

  # Regression — order #331 (Sep 27 2026). The supplier-cart safety gate sets
  # pending_review and tells the chef to "review and try again", but the order
  # page only offered Submit for pending and Retry for failed, and the Cart
  # excludes pending_review. The chef had no way forward on mobile or desktop.
  describe 'an order halted for review (pending_review)' do
    let(:mobile_ua) { { 'HTTP_USER_AGENT' => 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)' } }
    let!(:order) do
      create(:order, user: user, supplier: supplier, organization: org, location: location,
             status: 'pending_review',
             error_message: 'Supplier cart did not match your order, so we did not submit it.').tap do |o|
        create(:order_item, order: o, supplier_product: supplier_product)
      end
    end

    it 'offers Fix & Resubmit on the mobile order page' do
      get order_path(order), headers: mobile_ua
      expect(response.body).to include('Fix &amp; Resubmit')
    end

    it 'offers Retry and shows why it stopped on the desktop order page' do
      get order_path(order)
      expect(response.body).to include(retry_order_order_path(order))
      expect(response.body).to include('Supplier cart did not match your order')
    end

    # The reason is KEPT (order #386): wiping it left the chef with no idea
    # what to fix. It clears when she resubmits.
    it 'goes back to pending on Fix & Resubmit, keeping the reason on screen' do
      post retry_order_order_path(order)

      order.reload
      expect(order.status).to eq('pending')
      expect(order.error_message).to eq('Supplier cart did not match your order, so we did not submit it.')
      expect(order.order_items.count).to eq(1)
    end

    it 'still refuses Retry for an order that is being placed' do
      order.update!(status: 'processing')
      post retry_order_order_path(order)
      expect(order.reload.status).to eq('processing')
    end
  end
end
