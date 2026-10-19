require 'rails_helper'

# US Foods API changes for order placement (Oct 2026, plan Phase 1).
RSpec.describe Scrapers::UsFoodsApi do
  let(:supplier)   { create(:supplier, :two_fa) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:api)        { described_class.new(credential) }
  let(:orders_url) { "#{described_class::API_BASE}/order-domain-api/v1/orders" }

  before do
    api.instance_variable_set(:@access_token, 'tok-1')
    api.instance_variable_set(:@token_expires_at, 1.hour.from_now)
  end

  describe '#add_items_to_order' do
    let(:order) { { 'orderId' => 'ord-1', 'orderStatus' => 'IN_PROGRESS', 'orderItems' => [] } }
    let(:items) { [{ sku: 5_034_236, quantity: 2, vendor_id: 0 }] }

    # It used to return our locally-modified order, so checkout submitted a
    # cart US Foods had rejected.
    it 'returns nil — not our own copy — when US Foods rejects the update' do
      stub_request(:put, orders_url).to_return(status: 500, body: '')

      expect(api.add_items_to_order(order, items)).to be_nil
    end

    it 'returns nil — not someone else’s order — when ours is not in the answer' do
      stub_request(:put, orders_url)
        .to_return(status: 200, body: [{ 'orderId' => 'submitted-1', 'orderStatus' => 'SUBMITTED' }].to_json)

      expect(api.add_items_to_order(order, items)).to be_nil
    end

    it "returns US Foods' copy of our order" do
      stub_request(:put, orders_url).to_return(
        status: 200, body: [{ 'orderId' => 'x' }, { 'orderId' => 'ord-1', 'orderItems' => [{ 'productNumber' => 5_034_236 }] }].to_json
      )

      expect(api.add_items_to_order(order, items)['orderId']).to eq('ord-1')
    end
  end

  # A catalog import outlives the ~1-hour token; every call after expiry used
  # to come back nil, silently.
  describe 'session renewal during a run' do
    it 'renews and retries once on a 401' do
      stub_request(:get, orders_url).with(headers: { 'Authorization' => 'Bearer tok-1' }).to_return(status: 401, body: '')
      stub_request(:get, orders_url).with(headers: { 'Authorization' => 'Bearer tok-2' })
                                    .to_return(status: 200, body: [{ 'orderId' => 'ord-1' }].to_json)
      allow(api).to receive(:handle_auth_failure) { api.instance_variable_set(:@access_token, 'tok-2') && true }

      expect(api.get_orders).to eq([{ 'orderId' => 'ord-1' }])
      expect(api).to have_received(:handle_auth_failure).once
    end

    it 'renews an expired token before the call' do
      api.instance_variable_set(:@token_expires_at, 1.minute.ago)
      stub_request(:get, orders_url).with(headers: { 'Authorization' => 'Bearer tok-2' }).to_return(status: 200, body: '[]')
      allow(api).to receive(:handle_auth_failure) do
        api.instance_variable_set(:@access_token, 'tok-2')
        api.instance_variable_set(:@token_expires_at, 1.hour.from_now)
        true
      end

      expect(api.get_orders).to eq([])
    end

    it 'does not renew on every call when the expiry is unknown' do
      api.instance_variable_set(:@token_expires_at, nil)
      stub_request(:get, orders_url).to_return(status: 200, body: '[]')
      expect(api).not_to receive(:handle_auth_failure)

      api.get_orders
    end
  end
end
