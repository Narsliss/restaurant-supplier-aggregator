require 'rails_helper'

RSpec.describe Scrapers::ChefsWarehouseApi do
  let(:supplier) { create(:supplier) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:api) { described_class.new(credential) }

  describe '#parse_order_guide_item' do
    # Regression — CW's order-guide endpoint returns item['inStock']=false for
    # every line item regardless of real availability. The actual stock signal
    # lives on the variant: variant['inStock'] is a numeric stock count (10.0,
    # 31.0, 0.0). Reading the top-level field stranded every item in every
    # Tres Noches CW order guide as "out of stock" — 213/213 in the main list.
    # These four fixtures are the exact values observed against the live API
    # for SKUs the chef cross-checked on chefswarehouse.com.
    {
      'QG17520 (Graham Cracker Crumbs — in stock per CW.com)' => { variant_stock: 10.0, expected: true },
      'QZ105038 (Edible 23k Gold Leaf — in stock per CW.com)' => { variant_stock: 31.0, expected: true },
      'GS527 (Pomegranate Juice — in stock per CW.com)'       => { variant_stock: 2.0,  expected: true },
      'BC701496 (Manchego Sheep — out of stock per CW.com)'   => { variant_stock: 0.0,  expected: false }
    }.each do |label, fixture|
      it "derives availability from variant stock count: #{label}" do
        item = {
          'name' => 'Test Item', 'productCode' => 'JDE_TEST1', 'inStock' => false,
          'selectedVariant' => { 'inStock' => fixture[:variant_stock], 'code' => 'JDE_TEST1-800001', 'metadata' => {} }
        }
        parsed = api.send(:parse_order_guide_item, item)
        expect(parsed[:in_stock]).to eq(fixture[:expected])
        expect(parsed[:stock_count]).to eq(fixture[:variant_stock])
      end
    end

    it 'falls back to top-level inStock when variant stock count is missing' do
      item = {
        'name' => 'No Variant Stock', 'productCode' => 'JDE_X', 'inStock' => true,
        'selectedVariant' => { 'code' => 'JDE_X-1', 'metadata' => {} }
      }
      expect(api.send(:parse_order_guide_item, item)[:in_stock]).to be(true)
    end

    it 'treats a missing variant entirely as available (avoids stranding on parse gaps)' do
      item = { 'name' => 'Bare', 'productCode' => 'JDE_Y', 'inStock' => true }
      expect(api.send(:parse_order_guide_item, item)[:in_stock]).to be(true)
    end
  end
end
