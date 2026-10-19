require 'rails_helper'

# Plan 3.3 (Oct 2026): the price check is the last read of the supplier
# before the chef places the order. Every supplier now returns a definite
# in_stock (true / false) or nil when it can't tell, and reports_live_stock?
# so PriceVerificationService saves it. A placeholder "in stock" is gone.
RSpec.describe 'Live stock at the price check' do
  let(:credential) { create(:supplier_credential) }

  describe Scrapers::ChefsWarehouseScraper do
    let(:scraper) { described_class.new(credential) }
    let(:api) { double('ChefsWarehouseApi', ensure_session!: true) }

    before do
      allow(scraper).to receive(:api_client).and_return(api)
      allow(api).to receive(:fetch_prices) do |variants|
        variants.map { |v| { variant_code: v[:code], primary_price: 20.0 } }
      end
    end

    def by_sku = scraper.scrape_prices(%w[NW101B GF210 OFF1]).index_by { |r| r[:supplier_sku] }

    it "reads each item's live count from the order guides (walnuts at 0)" do
      allow(scraper).to receive(:load_order_guide_items)
        .and_return('NW101B' => { stock_count: 0.0 }, 'GF210' => { stock_count: 36.0 })

      expect(by_sku['NW101B']).to include(in_stock: false, stock_signal: '0.0', current_price: 20.0)
      expect(by_sku['GF210']).to include(in_stock: true, stock_signal: '36.0')
      expect(by_sku['OFF1']).to include(in_stock: nil) # on no guide: unknown
      expect(described_class.reports_live_stock?).to be(true)
    end

    it 'keeps the prices and reads stock as unknown when the guides cannot be read' do
      allow(scraper).to receive(:load_order_guide_items).and_raise(Scrapers::BaseScraper::ScrapingError, 'timeout')

      expect(by_sku['NW101B']).to include(in_stock: nil, current_price: 20.0)
    end
  end

  describe Scrapers::WhatChefsWantScraper do
    let(:scraper) { described_class.new(credential) }
    let(:api) { double('WhatChefsWantApi', ensure_session!: true) }

    before do
      allow(scraper).to receive(:api_client).and_return(api)
      allow(scraper).to receive(:fetch_all_order_guide_items).and_return([
        { 'itemCode' => 'W1', 'unavailable' => true },
        { 'itemCode' => 'W2', 'unavailable' => false },
        { 'itemCode' => 'W3' }
      ])
    end

    it 'reads unavailable, and nothing is "in" when WCW did not say' do
      results = scraper.scrape_prices(%w[W1 W2 W3]).index_by { |r| r[:supplier_sku] }

      expect(results['W1'][:in_stock]).to be(false)
      expect(results['W2'][:in_stock]).to be(true)
      expect(results['W3'][:in_stock]).to be_nil
      expect(described_class.reports_live_stock?).to be(true)
    end
  end

  describe Scrapers::PerformanceScraper do
    let(:scraper) { described_class.new(credential) }
    let(:api) { double('PerformanceApi', ensure_session!: true, fetch_prices: {}) }

    before do
      allow(scraper).to receive(:api_client).and_return(api)
      allow(scraper).to receive(:case_price_for).and_return(30.0)
      allow(scraper).to receive(:product_pack_size).and_return('1/5 LB')
      allow(api).to receive(:product_by_sku) do |sku|
        { 'ProductNumber' => sku, 'ProductDescription' => 'Item' }.merge(
          sku == 'P1' ? { 'IsOutOfStock' => true } : sku == 'P2' ? { 'IsOutOfStock' => false } : {}
        )
      end
    end

    it 'reads IsOutOfStock, and nothing is "in" when it is missing' do
      results = scraper.scrape_prices(%w[P1 P2 P3]).index_by { |r| r[:supplier_sku] }

      expect(results['P1']).to include(in_stock: false, stock_signal: 'IsOutOfStock:true')
      expect(results['P2'][:in_stock]).to be(true)
      expect(results['P3'][:in_stock]).to be_nil
      expect(described_class.reports_live_stock?).to be(true)
    end
  end

  describe Scrapers::SyscoScraper do
    let(:scraper) { described_class.new(credential) }

    def priced(id) = { 'productId' => id, 'priceInfoV2' => { 'case' => { 'netPrice' => 25.0 } } }

    before do
      allow(scraper).to receive(:ensure_api_session!)
      allow(scraper).to receive(:price_unit_for).and_return('CS')
      allow(scraper).to receive(:price_with_sellers)
        .and_return(prices: { 'S1' => priced('S1'), 'S2' => priced('S2'), 'S3' => priced('S3') })
    end

    it "reads the stock indicator from Sysco's search; a SKU it doesn't return is unknown" do
      allow(scraper).to receive(:graphql_search_products).and_return('results' => [
        { 'productId' => 'S1', 'availableStockInfo' => { 'stockIndicator' => 'O' }, 'productInfo' => {} },
        { 'productId' => 'S2', 'availableStockInfo' => { 'stockIndicator' => 'D' }, 'productInfo' => {} },
        { 'productId' => 'OTHER', 'availableStockInfo' => { 'stockIndicator' => 'O' }, 'productInfo' => {} }
      ])

      results = scraper.scrape_prices(%w[S1 S2 S3]).index_by { |r| r[:supplier_sku] }

      expect(results['S1']).to include(in_stock: false, current_price: 25.0)
      expect(results['S2'][:in_stock]).to be(true) # D = special order, still orderable
      expect(results['S3'][:in_stock]).to be_nil
      expect(described_class.reports_live_stock?).to be(true)
    end

    it 'keeps the prices and reads stock as unknown when the search fails' do
      allow(scraper).to receive(:graphql_search_products).and_raise(StandardError, 'boom')

      results = scraper.scrape_prices(%w[S1])

      expect(results.first).to include(in_stock: nil, current_price: 25.0)
    end
  end

  describe Scrapers::PremiereProduceOneScraper do
    let(:scraper) { described_class.new(credential) }
    let(:api) { double('PremiereProduceOneApi', ensure_session!: true) }

    def pack(uuid, sku) = { 'variant_pack' => { 'uuid' => uuid, 'external_item_id' => sku, 'item' => { 'display_name' => sku } } }

    before do
      allow(scraper).to receive(:api_client).and_return(api)
      allow(api).to receive(:get_catalog)
        .and_return('getSupplierVariantPackGroupItems' => [pack('v1', 'K1'), pack('v2', 'K2'), pack('v3', 'K3')])
      allow(api).to receive(:get_product_info_list).and_return('getVariantPackInfoList' => [
        { 'variant_pack_id' => 'v1', 'price_in_micros' => 10_000_000, 'availability_status' => 'OUT_OF_STOCK' },
        { 'variant_pack_id' => 'v2', 'price_in_micros' => 5_000_000, 'availability_status' => nil }
      ])
    end

    it 'reads the availability list; no entry is unknown, never "in"' do
      results = scraper.scrape_prices(%w[K1 K2 K3]).index_by { |r| r[:supplier_sku] }

      expect(results['K1']).to include(in_stock: false, stock_signal: 'OUT_OF_STOCK', current_price: 10.0)
      expect(results['K2']).to include(in_stock: true, stock_signal: 'available')
      expect(results['K3'][:in_stock]).to be_nil
      expect(described_class.reports_live_stock?).to be(true)
    end
  end
end
