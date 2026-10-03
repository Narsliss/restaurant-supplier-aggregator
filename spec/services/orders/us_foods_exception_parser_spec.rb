require 'rails_helper'

RSpec.describe Orders::UsFoodsExceptionParser do
  def parse(order)
    described_class.parse(order)
  end

  # Live recentorders payload for Alfio's, captured read-only Oct 3 2026 and
  # trimmed to the fields we read: #332 as US Foods re-filed it (archived after
  # delivery), a shipped order, and an abandoned draft.
  let(:live) { JSON.parse(file_fixture('usf_recent_orders_2026_10_03.json').read) }
  let(:order_332) { live.find { |o| o['tandemOrderNumber'].to_s == '648653' } }

  describe 'on live US Foods data' do
    it "finds exactly #332's two out-of-stocks: the vinegar and the chevre (0 of 1 reserved)" do
      expect(parse(order_332)).to contain_exactly(
        hash_including(sku: '4336327', type: 'out_of_stock', ordered: 1, filled: 0, message: 'Out of stock: 0 of 1 reserved'),
        hash_including(sku: '4917936', type: 'out_of_stock', ordered: 1, filled: 0)
      )
    end

    it 'does not report every line "removed" once US Foods archives the order (tandemDeleted on all lines)' do
      expect(order_332['orderItems']).to all(include('tandemDeleted' => true))
      expect(parse(order_332).map { |e| e[:type] }).not_to include('removed')
    end

    it 'does not crash on quantityAccepted, which is a true/false flag' do
      expect(order_332['orderItems'].map { |li| li['quantityAccepted'] }.uniq).to eq([true])
      expect { parse(order_332) }.not_to raise_error
    end

    it 'finds nothing on a fully reserved shipped order or an abandoned draft' do
      shipped = live.find { |o| o['orderStatus'] == 'SHIPPED' }
      draft = live.find { |o| o['orderStatus'] == 'DELETED' }
      expect(parse(shipped)).to eq([])
      expect(parse(draft)).to eq([])
    end
  end

  it 'returns [] for a clean, fully-reserved order' do
    order = {
      'orderExceptions' => [], 'errorDetails' => [],
      'orderItems' => [{ 'productNumber' => '123', 'unitsOrdered' => 5, 'unitsReserved' => 5, 'quantityAccepted' => true, 'productExceptionCount' => 0 }]
    }
    expect(parse(order)).to eq([])
  end

  it 'flags out of stock when none were reserved' do
    order = { 'orderItems' => [{ 'productNumber' => 'NP1', 'unitsOrdered' => 4, 'unitsReserved' => 0 }] }
    expect(parse(order)).to include(hash_including(sku: 'NP1', type: 'out_of_stock', ordered: 4, filled: 0))
  end

  it 'flags a short fill when fewer were reserved than ordered' do
    order = { 'orderItems' => [{ 'productNumber' => 'NP2', 'unitsOrdered' => 10, 'unitsReserved' => 6 }] }
    expect(parse(order)).to include(hash_including(sku: 'NP2', type: 'short_fill', ordered: 10, filled: 6))
  end

  it 'reads each-ordered lines from the eaches fields' do
    order = { 'orderItems' => [{ 'productNumber' => 'NP6', 'unitsOrdered' => 0, 'eachesOrdered' => 6, 'eachesReserved' => 2 }] }
    expect(parse(order)).to include(hash_including(sku: 'NP6', type: 'short_fill', ordered: 6, filled: 2, message: 'Only 2 of 6 each reserved'))
  end

  it 'reports nothing while US Foods has not reserved yet' do
    order = { 'orderItems' => [{ 'productNumber' => 'NP7', 'unitsOrdered' => 3, 'unitsReserved' => nil }] }
    expect(parse(order)).to eq([])
  end

  it 'flags a substitution, including US Foods\' "Y" flag' do
    order = { 'orderItems' => [{ 'productNumber' => 'NP3', 'unitsOrdered' => 2, 'substituteFlag' => true },
                               { 'productNumber' => 'NP8', 'unitsOrdered' => 1, 'originalProductWasSubbed' => 'Y' }] }
    expect(parse(order)).to include(hash_including(sku: 'NP3', type: 'substituted'), hash_including(sku: 'NP8', type: 'substituted'))
  end

  it 'flags a removed line (tandemDeleted) on an order that is still live' do
    order = { 'orderStatus' => 'SUBMITTED', 'orderItems' => [{ 'productNumber' => 'NP4', 'unitsOrdered' => 3, 'tandemDeleted' => true }] }
    expect(parse(order)).to include(hash_including(sku: 'NP4', type: 'removed', filled: 0))
  end

  it 'flags a line with a productExceptionCount as a generic issue' do
    order = { 'orderItems' => [{ 'productNumber' => 'NP5', 'unitsOrdered' => 1, 'unitsReserved' => 1, 'productExceptionCount' => 2 }] }
    expect(parse(order)).to include(hash_including(sku: 'NP5', type: 'other'))
  end

  it 'captures order-level orderExceptions and errorDetails' do
    order = {
      'orderExceptions' => [{ 'productNumber' => 'X', 'description' => 'Delivery delayed' }],
      'errorDetails' => [{ 'message' => 'Credit hold' }]
    }
    expect(parse(order).map { |e| e[:message] }).to include('Delivery delayed', 'Credit hold')
  end

  it 'flags a price change' do
    expect(parse('priceChangeFlag' => true, 'orderItems' => [])).to include(hash_including(type: 'price_change'))
  end

  it 'safely returns [] for a non-hash payload' do
    expect(parse(nil)).to eq([])
  end
end
