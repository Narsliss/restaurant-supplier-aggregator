require 'rails_helper'

RSpec.describe Scrapers::PerformanceScraper do
  let(:supplier) { create(:supplier) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:scraper) { described_class.new(credential) }

  describe '#scrape_prices (at-order verification — pure API, no browser)' do
    let(:api) { instance_double(Scrapers::PerformanceApi) }

    before do
      allow(scraper).to receive(:api_client).and_return(api)
      allow(api).to receive(:ensure_session!)
    end

    def catalog_product(sku, catchwt: false, avgwt: 10, pack: '2/5 LB')
      {
        'ProductNumber' => sku, 'ProductKey' => sku, 'ProductDescription' => 'CHICKEN', 'ProductBrand' => 'ROMA',
        'IsOutOfStock' => false,
        'UnitOfMeasureOrderQuantities' => [{
          'PackSize' => pack, 'UnitOfMeasureAbbreviation' => 'CS',
          'ProductIsCatchWeight' => catchwt, 'ProductAverageWeight' => avgwt
        }]
      }
    end

    it 'never opens a browser' do
      allow(api).to receive(:fetch_prices).and_return({})
      allow(api).to receive(:product_by_sku).and_return(nil)
      expect(scraper).not_to receive(:with_browser)
      scraper.scrape_prices(%w[541928])
    end

    it 'returns catch-weight-correct case prices for the queried SKUs' do
      allow(api).to receive(:fetch_prices).with(%w[541928 1008297]).and_return({ '541928' => 39.95, '1008297' => 1.65 })
      allow(api).to receive(:product_by_sku).with('541928').and_return(catalog_product('541928'))
      allow(api).to receive(:product_by_sku).with('1008297').and_return(catalog_product('1008297', catchwt: true, avgwt: 39, pack: '12/3.25 LB'))

      res = scraper.scrape_prices([{ sku: '541928', uom: 'CS' }, { sku: '1008297', uom: 'CS' }])
      expect(res.find { |r| r[:supplier_sku] == '541928' }[:current_price]).to eq(39.95)
      expect(res.find { |r| r[:supplier_sku] == '1008297' }[:current_price]).to eq(64.35) # 1.65 * 39
    end

    it 'skips a SKU whose lookup errors without aborting the rest' do
      allow(api).to receive(:fetch_prices).and_return({ '111' => 5.0, '222' => 6.0 })
      allow(api).to receive(:product_by_sku).with('111').and_raise(Scrapers::PerformanceApi::ApiError, 'boom')
      allow(api).to receive(:product_by_sku).with('222').and_return(catalog_product('222'))

      res = scraper.scrape_prices(%w[111 222])
      expect(res.map { |r| r[:supplier_sku] }).to eq(%w[222])
    end
  end

  describe '#scrape_lists (phase 5 — pure API, no browser)' do
    let(:api) { instance_double(Scrapers::PerformanceApi) }
    let(:list_id) { '225278a5-0996-49df-826a-1e90600b375e' }

    before do
      allow(scraper).to receive(:api_client).and_return(api)
      allow(api).to receive(:ensure_session!)
      allow(api).to receive(:account_context).and_return(customer_id: 'cust-guid')
    end

    def guide_entry(sku, desc, seq:, brand: 'PEAK', pack: '1/10 LB', catchwt: false, avgwt: 10)
      { product: {
          'ProductNumber' => sku, 'ProductKey' => sku, 'ProductDescription' => desc, 'ProductBrand' => brand,
          'IsOutOfStock' => false,
          'UnitOfMeasureOrderQuantities' => [{
            'PackSize' => pack, 'UnitOfMeasureAbbreviation' => 'CS',
            'ProductIsCatchWeight' => catchwt, 'ProductAverageWeight' => avgwt
          }]
        }, category_title: 'Uncategorized', sequence: seq }
    end

    it 'maps a real order guide, skipping the zero-GUID system list' do
      allow(api).to receive(:list_headers).and_return([
        { 'ProductListHeaderId' => list_id, 'ProductListTitle' => 'alfios', 'ProductListType' => 3 },
        { 'ProductListHeaderId' => '00000000-0000-0000-0000-000000000000', 'ProductListType' => 4 }
      ])
      allow(api).to receive(:list_products).with(list_id).and_return([
        guide_entry('328740', 'TOMATO 5X6 1 LAYER', seq: 0),
        guide_entry('543638', 'OIL POMACE OLIVE', seq: 1, brand: 'LUIGI', pack: '4/1 GA')
      ])
      allow(api).to receive(:fetch_prices).and_return({ '328740' => 18.5, '543638' => 41.0 })

      lists = scraper.scrape_lists
      expect(api).to have_received(:list_products).once # zero-GUID list skipped
      expect(lists.size).to eq(1)
      guide = lists.first
      expect(guide).to include(name: 'alfios', remote_id: list_id, list_type: 'order_guide')
      expect(guide[:url]).to end_with("/list-management/#{list_id}/cust-guid")
      expect(guide[:items].first).to include(
        sku: '328740', name: 'PEAK - TOMATO 5X6 1 LAYER', price: 18.5,
        pack_size: '1/10 LB CS', quantity: 1, in_stock: true, position: 0
      )
    end

    it 'applies catch-weight conversion to order-guide prices too' do
      allow(api).to receive(:list_headers).and_return([{ 'ProductListHeaderId' => list_id, 'ProductListTitle' => 'alfios' }])
      allow(api).to receive(:list_products).and_return([
        guide_entry('1008297', 'CHICKEN WITHOUT-GIBLETS', seq: 0, catchwt: true, avgwt: 39)
      ])
      allow(api).to receive(:fetch_prices).and_return({ '1008297' => 1.64 })

      item = scraper.scrape_lists.first[:items].first
      expect(item[:price]).to eq(63.96) # 1.64 * 39
    end

    it 'skips a guide that returns zero items instead of syncing it empty' do
      allow(api).to receive(:list_headers).and_return([{ 'ProductListHeaderId' => list_id, 'ProductListTitle' => 'alfios' }])
      allow(api).to receive(:list_products).and_return([])
      allow(api).to receive(:fetch_prices).and_return({})

      expect(scraper.scrape_lists).to eq([])
    end

    it 'never opens a browser' do
      allow(api).to receive(:list_headers).and_return([])
      expect(scraper).not_to receive(:with_browser)
      scraper.scrape_lists
    end
  end

  describe '#scrape_catalog (phase 3 — pure API, no browser)' do
    let(:api) { instance_double(Scrapers::PerformanceApi) }

    before do
      allow(scraper).to receive(:api_client).and_return(api)
      allow(api).to receive(:ensure_session!)
      allow(scraper).to receive(:rate_limit_delay)
    end

    def catalog_product(sku, desc, brand: 'ACME', pack: '2/5 LB', cat: 'POULTRY', shop: 'Wings')
      {
        'ProductNumber' => sku, 'ProductKey' => sku, 'ProductDescription' => desc, 'ProductBrand' => brand,
        'ProductCategory' => cat, 'ShoppingCategory' => shop,
        'ProductImageUrlThumbnail' => "https://blob/#{sku}.jpg",
        'UnitOfMeasureOrderQuantities' => [{ 'PackSize' => pack, 'UnitOfMeasureAbbreviation' => 'CS' }]
      }
    end

    it 'never opens a browser' do
      allow(api).to receive(:search_catalog).and_return({ 'CatalogProducts' => [], 'NumberOfPages' => 0 })
      allow(api).to receive(:fetch_prices).and_return({})
      expect(scraper).not_to receive(:with_browser)
      scraper.scrape_catalog(%w[chicken])
    end

    it 'maps products to the importer shape and merges prices' do
      allow(api).to receive(:search_catalog).with('chicken', page: 0, page_size: 25)
        .and_return({ 'CatalogProducts' => [catalog_product('541928', 'CHICKEN WING BONELESS')], 'NumberOfPages' => 1 })
      allow(api).to receive(:fetch_prices).with(['541928']).and_return({ '541928' => 42.19 })

      items = scraper.scrape_catalog(%w[chicken])
      expect(items.size).to eq(1)
      expect(items.first).to include(
        supplier_sku: '541928',
        supplier_name: 'ACME - CHICKEN WING BONELESS',
        current_price: 42.19,
        pack_size: '2/5 LB CS',
        category: 'Poultry',
        subcategory: 'Wings',
        in_stock: nil,
        image_url: 'https://blob/541928.jpg'
      )
    end

    it 'stops paginating when a page returns fewer than a full page' do
      allow(api).to receive(:search_catalog).with('beef', page: 0, page_size: 25)
        .and_return({ 'CatalogProducts' => [catalog_product('1', 'BEEF')], 'NumberOfPages' => 100 })
      allow(api).to receive(:fetch_prices).and_return({})

      scraper.scrape_catalog(%w[beef])
      expect(api).to have_received(:search_catalog).once
    end

    # Regression: PFG returns catch-weight prices PER POUND. Storing them raw
    # made a ~39 lb chicken case read as $1.64 instead of ~$64, which would make
    # PFG look ~40x cheaper than reality and corrupt savings comparisons.
    it 'converts a catch-weight per-pound price into a case price' do
      cw = catalog_product('1008297', 'CHICKEN WITHOUT-GIBLETS', pack: '12/3.25 LB')
      cw['UnitOfMeasureOrderQuantities'] = [{
        'PackSize' => '12/3.25 LB', 'UnitOfMeasureAbbreviation' => 'CS',
        'ProductIsCatchWeight' => true, 'ProductAverageWeight' => 39
      }]
      allow(api).to receive(:search_catalog).and_return({ 'CatalogProducts' => [cw], 'NumberOfPages' => 1 })
      allow(api).to receive(:fetch_prices).and_return({ '1008297' => 1.64 })

      item = scraper.scrape_catalog(%w[chicken]).first
      expect(item[:current_price]).to eq(63.96) # 1.64 * 39
    end

    it 'leaves a non-catch-weight case price unchanged' do
      fixed = catalog_product('541928', 'CHICKEN WING')
      fixed['UnitOfMeasureOrderQuantities'] = [{
        'PackSize' => '2/5 LB', 'UnitOfMeasureAbbreviation' => 'CS',
        'ProductIsCatchWeight' => false, 'ProductAverageWeight' => 10
      }]
      allow(api).to receive(:search_catalog).and_return({ 'CatalogProducts' => [fixed], 'NumberOfPages' => 1 })
      allow(api).to receive(:fetch_prices).and_return({ '541928' => 42.19 })

      item = scraper.scrape_catalog(%w[chicken]).first
      expect(item[:current_price]).to eq(42.19)
    end

    it 'de-duplicates a SKU seen under multiple terms' do
      dup = catalog_product('999', 'SHARED ITEM')
      allow(api).to receive(:search_catalog).and_return({ 'CatalogProducts' => [dup], 'NumberOfPages' => 1 })
      allow(api).to receive(:fetch_prices).and_return({ '999' => 5.0 })

      items = scraper.scrape_catalog(%w[chicken beef])
      expect(items.map { |i| i[:supplier_sku] }).to eq(['999'])
    end

    it 'yields batches to the block and returns [] in incremental mode' do
      allow(api).to receive(:search_catalog).and_return({ 'CatalogProducts' => [catalog_product('7', 'ITEM')], 'NumberOfPages' => 1 })
      allow(api).to receive(:fetch_prices).and_return({ '7' => 1.0 })

      batches = []
      result = scraper.scrape_catalog(%w[chicken]) { |b| batches << b }
      expect(result).to eq([])
      expect(batches.flatten.first[:supplier_sku]).to eq('7')
    end

    it 'skips a term whose search errors without aborting the whole import' do
      allow(api).to receive(:search_catalog).with('chicken', anything)
        .and_raise(Scrapers::PerformanceApi::ApiError, 'boom')
      allow(api).to receive(:search_catalog).with('beef', page: 0, page_size: 25)
        .and_return({ 'CatalogProducts' => [catalog_product('2', 'BEEF')], 'NumberOfPages' => 1 })
      allow(api).to receive(:fetch_prices).and_return({ '2' => 9.0 })

      items = scraper.scrape_catalog(%w[chicken beef])
      expect(items.map { |i| i[:supplier_sku] }).to eq(['2'])
    end
  end

  describe '#logged_in?' do
    let(:browser) { instance_double(Ferrum::Browser) }

    before { allow(scraper).to receive(:browser).and_return(browser) }

    it 'is false while still parked on the B2C identity host' do
      allow(browser).to receive(:current_url)
        .and_return('https://pfgcustomerfirst.b2clogin.com/pfgcustomerfirst.onmicrosoft.com/B2C_1A_signup_signin/')

      expect(scraper.logged_in?).to be(false)
    end

    it 'is true on the app origin once MSAL has cached tokens' do
      allow(browser).to receive(:current_url).and_return('https://www.customerfirstsolutions.com/home')
      allow(browser).to receive(:evaluate).and_return(true)

      expect(scraper.logged_in?).to be(true)
    end

    it 'is false on the app origin when storage has no MSAL entries (login bounced)' do
      allow(browser).to receive(:current_url).and_return('https://www.customerfirstsolutions.com/')
      allow(browser).to receive(:evaluate).and_return(false)

      expect(scraper.logged_in?).to be(false)
    end
  end

  describe 'supplier seeding' do
    it 'registers the performance supplier with password auth' do
      seed = Rails.root.join('config/initializers/seed_suppliers.rb').read
      expect(seed).to include("code: 'performance'")
      expect(seed).to include("scraper_class: 'Scrapers::PerformanceScraper'")
      expect(seed).to match(/code: 'performance',.*?auth_type: 'password'/m)
    end
  end
end
