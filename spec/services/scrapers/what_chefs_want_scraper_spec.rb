require 'rails_helper'

RSpec.describe Scrapers::WhatChefsWantScraper do
  let(:supplier) { create(:supplier) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:scraper) { described_class.new(credential) }
  let(:api_client) { instance_double(Scrapers::WhatChefsWantApi) }

  before do
    allow(scraper).to receive(:api_client).and_return(api_client)
    allow(api_client).to receive(:ensure_session!)
  end

  describe '#fetch_all_order_guide_items' do
    # Regression: WCW deprecated the applyCategorySort GraphQL argument
    # without warning. The scheduled order-guide sync kept getting HTTP 400
    # back, fetch_all_order_guide_items returned [], and ImportSupplierListsService
    # marked the list "synced" with zero items — stranding stock and prices
    # for several days. Failing loudly here forces the list into FAILED state
    # and surfaces the regression on the next sync.
    it 'raises when the API returns nil (transport error)' do
      allow(api_client).to receive(:get_order_guide_items).and_return(nil)

      expect { scraper.send(:fetch_all_order_guide_items) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, /no response/)
    end

    it 'raises when the API returns a GraphQL errors payload' do
      allow(api_client).to receive(:get_order_guide_items).and_return(
        'errors' => [{ 'message' => 'Unknown argument "applyCategorySort"' }]
      )

      expect { scraper.send(:fetch_all_order_guide_items) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, /applyCategorySort/)
    end

    it 'returns canonicalproducts when the API response is valid' do
      allow(api_client).to receive(:get_order_guide_items).with(limit: 100, offset: 0).and_return(
        'data' => {
          'formProducts' => {
            'sectionsWithCount' => {
              'sections' => [
                {
                  'multiUnitProducts' => [
                    {
                      'id' => '347160782', 'itemCode' => '20284', 'name' => 'Spinach - Flat Leaf',
                      'products' => [
                        { 'unit' => 'Case', 'canonicalproduct' => { 'itemCode' => '20284', 'description' => 'Spinach - Flat Leaf', 'packSize' => '4/2.5LB CS' } }
                      ]
                    }
                  ]
                }
              ]
            }
          }
        }
      )
      # second page returns no items, ending the loop
      allow(api_client).to receive(:get_order_guide_items).with(limit: 100, offset: 100).and_return(
        'data' => { 'formProducts' => { 'sectionsWithCount' => { 'sections' => [] } } }
      )

      items = scraper.send(:fetch_all_order_guide_items)
      expect(items.size).to eq(1)
      expect(items.first['itemCode']).to eq('20284')
    end
  end

  # Regression: the shallow scrape_catalog capped each category at 50 products,
  # so items deep in a large category (e.g. snapper in Seafood) were never
  # imported. scrape_catalog_deep must paginate the whole category.
  describe '#scrape_catalog_deep' do
    before do
      allow(scraper).to receive(:rate_limit_delay) # no real sleeps
      allow(api_client).to receive(:get_categories).and_return(
        'data' => { 'catalogCategoryOptions' => [
          { 'category' => { 'id' => 'c1', 'name' => 'Seafood' }, 'subcategories' => [] }
        ] }
      )
      allow(scraper).to receive(:format_api_product) { |cp, _name| { supplier_sku: cp['itemCode'] } }
    end

    def page(count, start)
      { 'data' => { 'catalogProductsRootQuery' => {
        'contextualProducts' => Array.new(count) { |i| { 'canonicalProduct' => { 'itemCode' => "SKU#{start + i}" } } }
      } } }
    end

    it 'paginates a category past the old 50-item cap until the API is exhausted' do
      allow(api_client).to receive(:browse_category) do |_cat, **kw|
        case kw[:offset]
        when 0   then page(50, 0)
        when 50  then page(50, 50)
        when 100 then page(20, 100) # 120 total — far past the old 50 cap
        else page(0, 0)
        end
      end

      collected = []
      scraper.scrape_catalog_deep { |batch| collected.concat(batch) }

      expect(collected.size).to eq(120)
      expect(collected.map { |p| p[:supplier_sku] }).to include('SKU0', 'SKU75', 'SKU119')
    end

    it 'stops a category at the safety ceiling instead of looping forever' do
      # API never returns an empty page → the DEEP_MAX_PAGES_PER_CATEGORY guard trips.
      allow(api_client).to receive(:browse_category) { |_cat, **kw| page(50, kw[:offset]) }

      collected = []
      scraper.scrape_catalog_deep { |batch| collected.concat(batch) }

      expect(collected.size).to eq(described_class::DEEP_MAX_PAGES_PER_CATEGORY * 50)
    end
  end
end
