require 'rails_helper'

# Phase 5 (Oct 19 2026): no edit lands once an order is being placed. Order
# 483: a quantity change was accepted 0.5 s after Submit. Submit and every
# edit take the order's row lock, and an edit re-checks under it.
RSpec.describe 'Editing an order while it is placed', type: :request do
  let(:user) { create(:user, :fully_onboarded) }
  let(:org) { user.current_organization }
  let(:supplier) { create(:supplier) }
  let(:supplier_product) { create(:supplier_product, supplier: supplier, current_price: 10.00) }
  let(:order) do
    create(:order, user: user, supplier: supplier, organization: org, location: org.locations.first, status: 'pending')
  end
  let!(:item) { create(:order_item, order: order, supplier_product: supplier_product, quantity: 2, unit_price: 10, line_total: 20) }

  before { sign_in user }

  it 'refuses a quantity change once placement has started, and says why' do
    order.update!(status: 'processing')

    patch order_order_item_path(order, item), params: { quantity: 5 }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to eq("This order is being placed, so it can't be changed now.")
    expect(item.reload.quantity).to eq(2)
  end

  it 'refuses removing a line once placement has started' do
    order.update!(status: 'processing')

    delete order_order_item_path(order, item), as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(OrderItem.exists?(item.id)).to be(true)
  end

  it 'still takes a quantity change on an order being edited' do
    patch order_order_item_path(order, item), params: { quantity: 5 }, as: :json

    expect(response).to have_http_status(:ok)
    expect(item.reload.quantity).to eq(5)
  end

  it 'starts placement once: a second Submit enqueues nothing' do
    expect { post submit_order_path(order) }.to have_enqueued_job(PlaceOrderJob).once
    expect(order.reload.status).to eq('processing')

    expect { post submit_order_path(order) }.not_to have_enqueued_job(PlaceOrderJob)
  end

  describe 'the race itself (Order#edit_while_editable, #start_placement!)' do
    it 'refuses an edit from a page loaded before Submit flipped the order' do
      stale = Order.find(order.id) # the edit request loaded the order while it was pending
      Order.find(order.id).start_placement!

      ran = false
      expect(stale.edit_while_editable { ran = true }).to be(false)
      expect(ran).to be(false)
    end

    it 'refuses to start placement from a stale copy that is no longer submittable' do
      stale = Order.find(order.id)
      Order.find(order.id).update!(status: 'processing')

      expect(stale.start_placement!).to be(false)
    end

    it 'clears the last attempt when it starts' do
      order.update!(error_message: 'Not placed. Earlier attempt.')

      expect(order.start_placement!(error_message: nil)).to be(true)
      expect(order.reload).to have_attributes(status: 'processing', error_message: nil)
    end
  end
end
