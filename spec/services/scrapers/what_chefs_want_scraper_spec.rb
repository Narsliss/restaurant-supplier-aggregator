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
end
