require 'rails_helper'

# Order #386 (Oct 1 2026): after the second failure the chef tapped "Retry
# Order", which reset the order AND wiped the reason. Her phone then showed a
# green Submit button, no explanation, and nothing marking the honey (the item
# CW refused). She cancelled. These specs walk that sequence on mobile.
RSpec.describe 'Fixing an order that was not placed', type: :request do
  MOBILE_UA_FIX = { 'HTTP_USER_AGENT' => 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)' }.freeze

  let(:user) { create(:user, :fully_onboarded) }
  let(:org) { user.current_organization }
  let(:location) { org.locations.first }
  let(:supplier) { create(:supplier, name: "Chef's Warehouse") }
  let(:oil) { create(:supplier_product, supplier: supplier, supplier_name: 'Extra Virgin Olive Oil', supplier_sku: 'GO135') }
  let(:honey) { create(:supplier_product, supplier: supplier, supplier_name: 'Classic Honey', supplier_sku: 'GH100') }
  let(:reason) { "Not placed. Chef's Warehouse couldn't take 1 item: Classic Honey — removed at checkout. Remove or change it and resubmit." }
  let!(:order) do
    create(:order, user: user, supplier: supplier, organization: org, location: location,
                   status: 'failed', error_message: reason, delivery_date: 3.days.from_now.to_date).tap do |o|
      create(:order_item, order: o, supplier_product: oil, quantity: 1, unit_price: 328.74, line_total: 328.74)
      create(:order_item, order: o, supplier_product: honey, quantity: 4, unit_price: 20.43, line_total: 81.72,
                          status: 'failed', notes: "Chef's Warehouse removed this item from the cart at checkout")
    end
  end

  def html(text) = ERB::Util.html_escape(text)

  before do
    sign_in user
    allow_any_instance_of(Supplier).to receive(:order_minimum).and_return(BigDecimal('400'))
  end

  it 'shows the failed order as NOT placed, with the refused item marked, on mobile' do
    get order_path(order), headers: MOBILE_UA_FIX

    body = response.body
    expect(body).to include('Order NOT placed', html(reason))
    expect(body).to include(html("Not taken by Chef's Warehouse:"), 'removed this item from the cart at checkout')
    expect(body).to include('Fix &amp; Resubmit')
    expect(body).not_to include('Retry Order')
  end

  it 'keeps the reason after Fix & Resubmit, and says what removing the item means' do
    post retry_order_order_path(order)

    expect(order.reload.status).to eq('pending')
    expect(order.error_message).to eq(reason)

    get order_path(order), headers: MOBILE_UA_FIX
    body = response.body
    expect(body).to include(html("Your last attempt wasn't placed. Fix this, then resubmit"), html(reason))
    expect(body).to include("Without Classic Honey you're <strong>$71.26 under</strong>")
    expect(body).to include('data-action="order-edit#removeItem" data-item-id="' + order.order_items.find_by(supplier_product: honey).id.to_s)
  end

  it 'wires the mobile quantity buttons to real controller actions' do
    post retry_order_order_path(order)
    get order_path(order), headers: MOBILE_UA_FIX

    expect(response.body).to include('click-&gt;order-edit#incrementItem', 'click-&gt;order-edit#decrementItem')
      .or include('click->order-edit#incrementItem')
    expect(response.body).not_to include('incrementQuantity')
    expect(response.body).not_to include('decrementQuantity')
  end

  it 'clears the old reason when the chef resubmits, and marks processing before queueing the job' do
    post retry_order_order_path(order)

    statuses_at_enqueue = []
    allow(PlaceOrderJob).to receive(:perform_later) { statuses_at_enqueue << order.reload.status }

    post submit_order_path(order)

    expect(statuses_at_enqueue).to eq(['processing'])
    expect(order.reload.error_message).to be_nil
  end

  describe 'the red NOT-placed bar on every screen' do
    it 'shows on other mobile screens, with a "Don\'t place" dismiss' do
      get orders_path, headers: MOBILE_UA_FIX

      body = response.body
      expect(body).to include('data-unplaced-orders-bar', '1 order NOT placed', 'NOT placed. Tap to fix')
      expect(body).to include(cancel_order_path(order), "Don't place")
    end

    it 'shows on desktop too' do
      get orders_path

      expect(response.body).to include('data-unplaced-orders-bar')
    end

    it "is not repeated on the failed order's own page" do
      get order_path(order), headers: MOBILE_UA_FIX

      expect(response.body).not_to include('data-unplaced-orders-bar')
    end

    it '"Don\'t place" cancels the order and the bar goes away' do
      post cancel_order_path(order)

      expect(order.reload.status).to eq('cancelled')
      get orders_path, headers: MOBILE_UA_FIX
      expect(response.body).not_to include('data-unplaced-orders-bar')
    end

    it 'goes away once the order is placed' do
      order.update!(status: 'submitted', submitted_at: Time.current, error_message: nil)

      get orders_path, headers: MOBILE_UA_FIX

      expect(response.body).not_to include('data-unplaced-orders-bar')
    end

    it 'offers no "Don\'t place" for an order the supplier may already have' do
      order.update!(status: 'pending_manual', error_message: 'Check the Premiere Produce app before reordering')

      get orders_path, headers: MOBILE_UA_FIX

      expect(response.body).to include('before reordering')
      expect(response.body).not_to include(cancel_order_path(order))
    end
  end

  describe Order, '.needing_chef_attention' do
    def attention = Order.needing_chef_attention(user).to_a

    it 'includes a failed order and a fixed-but-not-resubmitted one' do
      fixed = create(:order, user: user, supplier: supplier, organization: org, status: 'pending', error_message: 'Not placed.')
      expect(attention).to include(order, fixed)
    end

    it 'leaves out ordinary drafts, placed and cancelled orders' do
      draft = create(:order, user: user, supplier: supplier, organization: org, status: 'pending')
      placed = create(:order, user: user, supplier: supplier, organization: org, status: 'submitted')
      cancelled = create(:order, user: user, supplier: supplier, organization: org, status: 'cancelled', error_message: 'x')
      expect(attention).not_to include(draft, placed, cancelled)
    end

    it 'leaves out orders whose delivery date has passed, and other chefs\' orders' do
      past = create(:order, user: user, supplier: supplier, organization: org, status: 'failed', delivery_date: Date.yesterday)
      theirs = create(:order, user: create(:user), supplier: supplier, organization: org, status: 'failed')
      expect(attention).not_to include(past, theirs)
    end

    it 'includes an order stuck processing for over 15 minutes, not a fresh one' do
      fresh = create(:order, user: user, supplier: supplier, organization: org, status: 'processing')
      stuck = create(:order, user: user, supplier: supplier, organization: org, status: 'processing')
      stuck.update_column(:updated_at, 20.minutes.ago)
      expect(attention).to include(stuck)
      expect(attention).not_to include(fresh)
    end
  end

  it 'shows no failure notice once the order is placed' do
    order.update!(status: 'submitted', submitted_at: Time.current, confirmation_number: 'TCW1')

    get order_path(order), headers: MOBILE_UA_FIX

    expect(response.body).not_to include('data-order-failure-notice')
  end
end
