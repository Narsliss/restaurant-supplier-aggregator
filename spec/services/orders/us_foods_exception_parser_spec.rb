require 'rails_helper'

RSpec.describe Orders::UsFoodsExceptionParser do
  def parse(order)
    described_class.parse(order)
  end

  it 'returns [] for a clean, fully-filled order' do
    order = {
      'orderExceptions' => [], 'errorDetails' => [],
      'orderItems' => [{ 'productNumber' => '123', 'unitsOrdered' => 5, 'quantityAccepted' => 5, 'productExceptionCount' => 0 }]
    }
    expect(parse(order)).to eq([])
  end

  it 'flags out of stock when none were accepted' do
    order = { 'orderItems' => [{ 'productNumber' => 'NP1', 'unitsOrdered' => 4, 'quantityAccepted' => 0 }] }
    expect(parse(order)).to include(hash_including(sku: 'NP1', type: 'out_of_stock', ordered: 4, filled: 0))
  end

  it 'flags a short fill when fewer were accepted than ordered' do
    order = { 'orderItems' => [{ 'productNumber' => 'NP2', 'unitsOrdered' => 10, 'quantityAccepted' => 6 }] }
    expect(parse(order)).to include(hash_including(sku: 'NP2', type: 'short_fill', ordered: 10, filled: 6))
  end

  it 'flags a substitution' do
    order = { 'orderItems' => [{ 'productNumber' => 'NP3', 'unitsOrdered' => 2, 'substituteFlag' => true }] }
    expect(parse(order)).to include(hash_including(sku: 'NP3', type: 'substituted'))
  end

  it 'flags a removed line (tandemDeleted)' do
    order = { 'orderItems' => [{ 'productNumber' => 'NP4', 'unitsOrdered' => 3, 'tandemDeleted' => true }] }
    expect(parse(order)).to include(hash_including(sku: 'NP4', type: 'removed', filled: 0))
  end

  it 'flags a line with a productExceptionCount as a generic issue' do
    order = { 'orderItems' => [{ 'productNumber' => 'NP5', 'unitsOrdered' => 1, 'quantityAccepted' => 1, 'productExceptionCount' => 2 }] }
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
