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

  describe '#list_order_guides' do
    # Regression: the id regex used \d+ and silently dropped CW's synthetic
    # "Recently Purchased" guide (id=-1) — the seed source for the
    # "Recent Chef's Warehouse Orders" onboarding list. Caught live by
    # Carmin's sandbox onboarding test (alfio's account imported only the
    # two positive-id guides).
    it 'captures the negative-id Recently Purchased guide' do
      allow(api).to receive(:get_json).with('/web-api/order-guide/header-list').and_return([
        { 'text' => 'Recently Purchased', 'href' => '/account-dashboard/order-guides/detail/?id=-1' },
        { 'text' => 'Alfio Full Order Guide', 'href' => '/account-dashboard/order-guides/detail/?id=411172&type=user' }
      ])

      guides = api.list_order_guides

      expect(guides.map { |g| g[:remote_id] }).to eq(%w[-1 411172])
    end
  end

  describe '#parse_search_product' do
    # The catalog/search endpoint shares the order-guide endpoint's quirk:
    # variants[0]['inStock'] is a numeric stock count, not a boolean. Passing
    # the raw count downstream is unsafe — import_new_item does
    # `item[:in_stock] != false`, which is `true` for 0.0, so new SKUs from
    # catalog imports were getting in_stock=true regardless of actual stock.
    it 'returns in_stock=true for a positive variant stock count' do
      product = { 'name' => 'Live Item', 'sku' => 'X1', 'variants' => [{ 'inStock' => 10.0, 'code' => 'JDE_X1-1', 'metadata' => {} }] }
      parsed = api.send(:parse_search_product, product)
      expect(parsed[:in_stock]).to be(true)
      expect(parsed[:stock_count]).to eq(10.0)
    end

    it 'returns in_stock=false for zero variant stock count' do
      product = { 'name' => 'Sold Out', 'sku' => 'X2', 'variants' => [{ 'inStock' => 0.0, 'code' => 'JDE_X2-1', 'metadata' => {} }] }
      parsed = api.send(:parse_search_product, product)
      expect(parsed[:in_stock]).to be(false)
      expect(parsed[:stock_count]).to eq(0.0)
    end

    it 'defaults to in_stock=true when the variant has no inStock field (avoids stranding fresh SKUs)' do
      product = { 'name' => 'Unknown', 'sku' => 'X3', 'variants' => [{ 'code' => 'JDE_X3-1', 'metadata' => {} }] }
      expect(api.send(:parse_search_product, product)[:in_stock]).to be(true)
    end

    it 'handles a missing variants array gracefully' do
      product = { 'name' => 'No Variants', 'sku' => 'X4' }
      expect(api.send(:parse_search_product, product)[:in_stock]).to be(true)
    end
  end
end
