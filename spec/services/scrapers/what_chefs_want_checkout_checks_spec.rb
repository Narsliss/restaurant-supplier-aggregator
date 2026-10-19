require 'rails_helper'

# Plan Phase 4 (Oct 19 2026): What Chefs Want sends nothing on a failed guide
# read, refuses items whose unit it would pick itself, keeps its own error
# text, and never calls an unanswered submit placed or failed.
RSpec.describe Scrapers::WhatChefsWantScraper, 'checkout checks' do
  let(:supplier) { create(:supplier) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:scraper) { described_class.new(credential) }
  let(:api) { instance_double(Scrapers::WhatChefsWantApi, last_error: nil) }

  let(:chicken) { { sku: '18271', name: 'Chicken - Breast 6OZ', quantity: 1, expected_price: 107.90 } }
  let(:pear) { { sku: '95839', name: 'Perfect Puree - Pear', quantity: 3, expected_price: 17.15 } }

  def guide_page(*mups)
    { 'data' => { 'formProducts' => { 'sectionsWithCount' => { 'sections' => [{ 'multiUnitProducts' => mups }] } } } }
  end

  def mup(id, code, units)
    { 'id' => id, 'itemCode' => code,
      'products' => units.map { |u| { 'unit' => u, 'canonicalproduct' => { 'itemCode' => code } } } }
  end

  before do
    allow(scraper).to receive(:api_client).and_return(api)
    allow(api).to receive(:ensure_session!)
    allow(api).to receive(:create_draft).and_return('data' => { 'CreateOrUpdateDraftMutation' => { 'id' => 'D1', 'itemCount' => 1 } })
    allow(api).to receive(:create_hidden_shop_product)
    allow(scraper).to receive(:resolve_product_id_via_search) { |sku| "canonical-#{sku}" }
  end

  describe 'reading the order guide' do
    it 'sends nothing when the guide read fails' do
      allow(api).to receive(:get_order_guide_items).and_return(nil)
      allow(api).to receive(:last_error).and_return('HTTP 502')

      expect { scraper.add_to_cart([chicken]) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, "Couldn't read your What Chefs Want order guide, so nothing was sent: HTTP 502")
      expect(api).not_to have_received(:create_hidden_shop_product)
      expect(api).not_to have_received(:create_draft)
    end

    it 'sends nothing when the guide answers with errors' do
      allow(api).to receive(:get_order_guide_items).and_return('errors' => [{ 'message' => 'Unknown argument useElasticSearch' }])

      expect { scraper.add_to_cart([chicken]) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, /Unknown argument useElasticSearch/)
      expect(api).not_to have_received(:create_draft)
    end
  end

  describe 'items sold in more than one unit' do
    it 'refuses a guide item What Chefs Want sells in several units, and orders the rest' do
      allow(api).to receive(:get_order_guide_items).and_return(
        guide_page(mup('mup-18271', '18271', %w[case lb]), mup('mup-95839', '95839', %w[case]))
      )

      result = scraper.add_to_cart([chicken, pear])

      expect(result[:failed]).to eq([{ sku: '18271', name: 'Chicken - Breast 6OZ',
                                       error: "comes in more than one unit at What Chefs Want (case, lb) and EnPlace can't pick which yet; order it on What Chefs Want's site" }])
      expect(api).to have_received(:create_draft).with(nil, [hash_including(product_id: 'mup-95839', quantity: 3)])
    end

    it 'refuses an off-guide item that comes back with several units' do
      allow(api).to receive(:get_order_guide_items).and_return(guide_page(mup('mup-95839', '95839', %w[case])))
      allow(api).to receive(:create_hidden_shop_product).and_return(mup('hidden-1', '18271', %w[each case]))

      result = scraper.add_to_cart([chicken, pear])

      expect(result[:failed].map { |f| f[:sku] }).to eq(['18271'])
      expect(result[:failed].first[:error]).to start_with('comes in more than one unit at What Chefs Want (each, case)')
    end

    it 'orders a single-unit item as before' do
      allow(api).to receive(:get_order_guide_items).and_return(guide_page(mup('mup-18271', '18271', %w[case])))

      expect(scraper.add_to_cart([chicken])[:failed]).to be_empty
    end
  end

  describe "keeping What Chefs Want's reason" do
    before { allow(api).to receive(:get_order_guide_items).and_return(guide_page(mup('mup-95839', '95839', %w[case]))) }

    it 'names why an off-guide item could not be attached' do
      allow(api).to receive(:create_hidden_shop_product).and_return(nil)
      allow(api).to receive(:last_error).and_return('Product is not available for this location')

      result = scraper.add_to_cart([chicken, pear])

      expect(result[:failed].first[:error])
        .to eq("What Chefs Want couldn't add it from its catalog: Product is not available for this location")
    end

    it 'names why the cart could not be created' do
      allow(api).to receive(:create_draft).and_return('errors' => [{ 'message' => 'Delivery date is not available' }])

      expect { scraper.add_to_cart([pear]) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError,
                        "What Chefs Want didn't create the cart, so nothing was sent: Delivery date is not available")
    end
  end

  describe 'the submit' do
    let(:draft) do
      { 'data' => { 'draft' => { 'id' => 'D1', 'itemCount' => 3, 'date' => '2026-10-21',
                                 'products' => [{ 'id' => 'l1', 'quantity' => 3, 'itemCode' => '95839', 'multiUnitProduct' => { 'id' => 'mup-95839' } }] } } }
    end

    before do
      scraper.instance_variable_set(:@last_wcw_draft_id, 'D1')
      allow(api).to receive(:get_draft).and_return(draft)
      allow(api).to receive(:get_order_minimum).and_return({})
    end

    it 'calls a timed-out submit unconfirmed' do
      allow(api).to receive(:submit_order).and_raise(Net::ReadTimeout)

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError, /didn't answer.*before reordering/)
    end

    it 'calls an error answer unconfirmed, naming it' do
      allow(api).to receive(:submit_order).and_return(nil)
      allow(api).to receive(:last_error).and_return('HTTP 502')

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError, /answered this order with HTTP 502/)
    end

    it "fails plainly, in What Chefs Want's words, when it refuses the order" do
      allow(api).to receive(:submit_order).and_return('data' => { 'CreateNewOrderMutation' => nil },
                                                      'errors' => [{ 'message' => 'Order minimum not met' }])

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, 'What Chefs Want refused the order: Order minimum not met') { |e|
          expect(e).not_to be_a(Scrapers::BaseScraper::OrderUnconfirmedError)
        }
    end
  end
end

RSpec.describe Scrapers::WhatChefsWantApi, 'last_error' do
  let(:supplier) { create(:supplier) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:api) { described_class.new(credential) }

  def call
    api.send(:graphql_request, 'CreateNewOrderMutation', 'mutation {}', {})
  end

  it 'keeps the HTTP status of a failed call and clears it after a clean one' do
    stub_request(:post, described_class::GRAPHQL_URL).to_return(
      { status: 502, body: 'Bad gateway' },
      { status: 200, body: { data: { ok: true } }.to_json }
    )

    expect(call).to be_nil
    expect(api.last_error).to eq('HTTP 502')
    expect(call).to eq('data' => { 'ok' => true })
    expect(api.last_error).to be_nil
  end

  it "keeps What Chefs Want's GraphQL error text" do
    stub_request(:post, described_class::GRAPHQL_URL).to_return(
      status: 200, body: { data: nil, errors: [{ message: 'Order minimum not met' }] }.to_json
    )

    call
    expect(api.last_error).to eq('Order minimum not met')
  end
end
