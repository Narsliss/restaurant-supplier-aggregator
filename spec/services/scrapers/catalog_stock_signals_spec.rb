require 'rails_helper'

# What each supplier's morning catalog run reports about stock (plan Phase 3,
# Oct 2026; signals confirmed by read-only live probes on Oct 19). The
# importer only acts on a definite in_stock (true/false); nil means "can't tell".
RSpec.describe 'Catalog stock signals' do
  let(:credential) { create(:supplier_credential) }

  describe Scrapers::PerformanceScraper do
    let(:scraper) { described_class.new(credential) }

    def formatted(fields)
      allow(scraper).to receive(:case_price_for).and_return(10.0)
      allow(scraper).to receive(:product_pack_size).and_return('6/1 L')
      scraper.send(:format_catalog_product, { 'ProductNumber' => 428_482, 'ProductDescription' => 'Truffle Oil' }.merge(fields), {})
    end

    it 'reads IsOutOfStock from the search answer it already gets (it used to be ignored)' do
      expect(formatted('IsOutOfStock' => true)).to include(in_stock: false, stock_signal: 'IsOutOfStock:true')
      expect(formatted('IsOutOfStock' => false)).to include(in_stock: true, stock_signal: 'IsOutOfStock:false')
    end

    it 'is unknown when the field is missing' do
      expect(formatted({})).to include(in_stock: nil, stock_signal: nil)
    end
  end

  describe Scrapers::SyscoScraper do
    let(:scraper) { described_class.new(credential) }

    def parsed(stock_indicator:, orderable: true, phased_out: false)
      result = {
        'productId' => '6000001',
        'seller' => { 'group' => described_class::LOCAL_SALES_GROUP },
        'availableStockInfo' => { 'stockIndicator' => stock_indicator },
        'productInfo' => { 'name' => 'Item', 'isOrderable' => orderable, 'isShopOrderable' => true,
                           'isPhasedOut' => phased_out, 'stockType' => 'DEMAND', 'packSize' => {} }
      }
      scraper.send(:parse_search_result, result, {})
    end

    it 'keeps demand (special-order) items in stock and records the raw indicator' do
      item = parsed(stock_indicator: 'D')

      expect(item[:in_stock]).to be(true)
      expect(item[:stock_signal]).to include('"D"', 'DEMAND', 'orderable:true')
    end

    it "marks 'O', phased-out and not-orderable items out" do
      expect(parsed(stock_indicator: 'O')[:in_stock]).to be(false)
      expect(parsed(stock_indicator: 'S', phased_out: true)[:in_stock]).to be(false)
      expect(parsed(stock_indicator: 'S', orderable: false)[:in_stock]).to be(false)
    end
  end

  describe Scrapers::UsFoodsScraper do
    let(:scraper) { described_class.new(credential) }

    it 'keeps the raw inventory numbers as evidence' do
      product = { 'inventory' => { 'casesOnHand' => 14, 'casesOnReserve' => 2, 'casesWaitlistReserve' => 0, 'productType' => 'R' } }

      expect(scraper.usf_stock_signal(product)).to eq('on 14 res 2 wait 0 R')
      expect(scraper.usf_stock_signal({})).to be_nil
    end
  end

  describe Scrapers::PremiereProduceOneScraper do
    let(:scraper) { described_class.new(credential) }

    it 'only reads OUT_OF_STOCK as out; a missing entry is unknown' do
      expect(scraper.send(:ppo_in_stock, { 'availability_status' => 'OUT_OF_STOCK' })).to be(false)
      expect(scraper.send(:ppo_in_stock, { 'availability_status' => nil })).to be(true)
      expect(scraper.send(:ppo_in_stock, nil)).to be_nil
    end
  end
end
