require 'rails_helper'

# Phase 5 (Oct 19 2026): the refused line is easy to find and fix on every
# order screen, and a stop that sent nothing never reads "check before
# reordering".
RSpec.describe 'Order screens after a stop', type: :request do
  MOBILE_UA_SCREENS = { 'HTTP_USER_AGENT' => 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)' }.freeze

  let(:user) { create(:user, :fully_onboarded) }
  let(:org) { user.current_organization }
  let(:supplier) { create(:supplier, name: "Chef's Warehouse") }
  let(:oil) { create(:supplier_product, supplier: supplier, supplier_name: 'Extra Virgin Olive Oil', supplier_sku: 'GO135') }
  let(:walnuts) { create(:supplier_product, supplier: supplier, supplier_name: 'Walnut Halves', supplier_sku: 'NW101B') }
  let(:reason) { "Not placed. Chef's Warehouse couldn't take 1 item: Walnut Halves — Out of stock. Remove or change it and resubmit." }
  let!(:order) do
    create(:order, user: user, supplier: supplier, organization: org, location: org.locations.first, batch_id: 'b-1',
                   status: 'failed', error_message: reason, delivery_date: 3.days.from_now.to_date).tap do |o|
      create(:order_item, order: o, supplier_product: oil, quantity: 1, unit_price: 328.74, line_total: 328.74)
      create(:order_item, order: o, supplier_product: walnuts, quantity: 2, unit_price: 42.10, line_total: 84.20,
                          status: 'failed', notes: 'Out of stock')
    end
  end

  def html(text) = ERB::Util.html_escape(text)

  before { sign_in user }

  describe 'the refused line' do
    it 'comes first on the phone (order 483 had 30 lines)' do
      get order_path(order), headers: MOBILE_UA_SCREENS

      expect(response.body.index('Walnut Halves')).to be < response.body.index('Extra Virgin Olive Oil')
    end

    it 'is red with the reason on desktop, before and after Fix & Resubmit' do
      get order_path(order)
      expect(response.body).to include('data-refused-reason', html("Not taken by Chef's Warehouse:"), 'Out of stock', '>Not taken<')

      post retry_order_order_path(order)
      get order_path(order)
      expect(response.body).to include('data-refused-reason', html("Not taken by Chef's Warehouse:"))
      ids = order.order_items.to_h { |i| [i.supplier_product_id, i.id] }
      expect(response.body.index("data-item-id=\"#{ids[walnuts.id]}\""))
        .to be < response.body.index("data-item-id=\"#{ids[oil.id]}\"")
    end

    it 'is not marked once the order is placed' do
      order.update!(status: 'submitted', error_message: nil, confirmation_number: 'C1')

      get order_path(order)
      expect(response.body).not_to include('data-refused-reason')
    end
  end

  describe 'a stop that sent nothing (sign-in code, robot check)' do
    before do
      order.update!(status: 'pending_manual',
                    error_message: "Not placed yet. Chef's Warehouse needs a sign-in code. Enter the code when EnPlace asks for it " \
                                   "(or reconnect Chef's Warehouse under Suppliers), then resubmit.")
    end

    it 'says NOT placed, not "check before reordering"' do
      get order_path(order)

      expect(response.body).to include('Order NOT placed')
      expect(response.body).not_to include('Check with the supplier before reordering')
    end

    it 'says NOT placed on the red bar too' do
      get orders_path, headers: MOBILE_UA_SCREENS

      expect(response.body).to include('NOT placed. Tap to fix')
      expect(response.body).not_to include(html("Check with Chef's Warehouse before reordering"))
    end
  end

  it 'still says "check before reordering" for an unconfirmed submit' do
    order.update!(status: 'pending_manual', error_message: "We sent this order to Chef's Warehouse, then something went wrong…")

    get order_path(order)
    expect(response.body).to include('Check with the supplier before reordering')
  end

  describe 'batch progress' do
    it 'offers Fix & Resubmit and the reason for an order that needs review' do
      order.update!(status: 'pending_review', error_message: 'Supplier cart did not match your order, so we did not submit it: …')

      get batch_progress_orders_path(batch_id: 'b-1')

      card = response.body[response.body.index("data-order-id=\"#{order.id}\"")..]
      expect(card).to include('Not placed: review', 'Supplier cart did not match your order')
      expect(card[/data-retry-wrapper class="([^"]*)"/, 1]).not_to include('hidden')
      # Not also "still waiting to be submitted": its card has the fix.
      expect(response.body).not_to include('still waiting to be submitted')
    end

    it 'shows no retry for an order the supplier may have' do
      order.update!(status: 'pending_manual', error_message: "We sent this order to Chef's Warehouse, then something went wrong…")

      get batch_progress_orders_path(batch_id: 'b-1')

      card = response.body[response.body.index("data-order-id=\"#{order.id}\"")..]
      expect(card).to include('Check supplier')
      expect(card[/data-retry-wrapper class="([^"]*)"/, 1]).to include('hidden')
    end
  end
end
