require 'rails_helper'

# Order #388 (Oct 1 2026, Noche): chicken was on the chef's What Chefs Want
# order guide; blackberries (10407) and pear purée (95839) weren't. Their
# catalog-search fallback ids didn't take in the draft, nothing re-read the
# draft, and WCW placed 1 item / $107.90 while EnPlace showed 3 / $170.35.
RSpec.describe Scrapers::WhatChefsWantScraper, 'cart check before submit' do
  let(:supplier) { create(:supplier) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:scraper) { described_class.new(credential) }
  let(:api) { instance_double(Scrapers::WhatChefsWantApi) }

  let(:order_items) do
    [{ sku: '18271', name: 'Chicken - Breast 6OZ', quantity: 1, expected_price: 107.90 },
     { sku: '10407', name: 'Blackberries - Market Clam', quantity: 2, expected_price: 5.50 },
     { sku: '95839', name: 'Perfect Puree - Pear', quantity: 3, expected_price: 17.15 }]
  end

  def draft_line(code, qty, mup_code: code, variants: [])
    { 'id' => "line-#{code}", 'quantity' => qty, 'itemCode' => code,
      'multiUnitProduct' => { 'id' => "mup-#{code}", 'itemCode' => mup_code,
                              'products' => variants.map { |v| { 'itemCode' => v, 'canonicalproduct' => { 'itemCode' => v } } } } }
  end

  def draft_with(*lines)
    { 'data' => { 'draft' => { 'id' => 'D1', 'itemCount' => lines.sum { |l| l['quantity'] }, 'products' => lines } } }
  end

  before do
    allow(scraper).to receive(:api_client).and_return(api)
    allow(api).to receive(:ensure_session!)
    allow(api).to receive(:delete_draft_items)
    allow(scraper).to receive(:build_order_guide_mup_map).and_return('18271' => 'mup-18271')
    allow(scraper).to receive(:resolve_product_id_via_search) { |sku| "canonical-#{sku}" }
    allow(api).to receive(:create_hidden_shop_product) { |cid| { 'id' => "hidden-#{cid}" } }
    allow(api).to receive(:create_draft).and_return('data' => { 'CreateOrUpdateDraftMutation' => { 'id' => 'D1', 'itemCount' => 6 } })
    scraper.add_to_cart(order_items, delivery_date: Date.new(2026, 10, 2))
  end

  # How WCW's own site adds a searched item (captured Oct 3 2026):
  # CreateHiddenShopProductMutation(canonicalProductId) -> multi-unit product
  # id, then that id goes into the draft.
  describe 'ordering items that are not on the order guide' do
    it 'attaches each off-guide item to the order form and orders the id WCW returns' do
      expect(api).to have_received(:create_hidden_shop_product).with('canonical-10407')
      expect(api).to have_received(:create_hidden_shop_product).with('canonical-95839')
      expect(api).not_to have_received(:create_hidden_shop_product).with('canonical-18271')
      expect(api).to have_received(:create_draft).with(
        Date.new(2026, 10, 2).strftime('%Y-%m-%d'),
        [hash_including(product_id: 'mup-18271', quantity: 1),
         hash_including(product_id: 'hidden-canonical-10407', quantity: 2),
         hash_including(product_id: 'hidden-canonical-95839', quantity: 3)]
      )
    end

    it 'reports an off-guide item WCW would not attach, instead of ordering without it' do
      fresh = described_class.new(credential)
      allow(fresh).to receive(:api_client).and_return(api)
      allow(fresh).to receive(:build_order_guide_mup_map).and_return('18271' => 'mup-18271')
      allow(fresh).to receive(:resolve_product_id_via_search) { |sku| "canonical-#{sku}" }
      allow(api).to receive(:create_hidden_shop_product).and_return(nil)

      result = fresh.add_to_cart(order_items, delivery_date: Date.new(2026, 10, 2))

      expect(result[:failed].map { |f| f[:sku] }).to eq(%w[10407 95839])
      expect(result[:failed].first[:error]).to eq("What Chefs Want couldn't add it from its catalog")
    end

    it 'never orders a different product than the SKU (exact item code only)' do
      fresh = described_class.new(credential)
      allow(fresh).to receive(:api_client).and_return(api)
      allow(api).to receive(:search_products).and_return(
        'data' => { 'catalogProductsSearchRootQuery' => { 'contextualProducts' => [
          { 'canonicalProduct' => { 'id' => '999', 'itemCode' => '10403' } } # strawberries, not 10407
        ] } }
      )

      expect(fresh.send(:resolve_product_id_via_search, '10407')).to be_nil
    end
  end

  it "stops the order and names the off-guide items WCW didn't take (the #388 case)" do
    allow(api).to receive(:get_draft).and_return(draft_with(draft_line('18271', 1)))

    expect { scraper.verify_cart_matches!(order_items) }.to raise_error(Scrapers::BaseScraper::ItemUnavailableError) { |e|
      expect(e.items.map { |i| i[:sku] }).to eq(%w[10407 95839])
      expect(e.items.first).to include(name: 'Blackberries - Market Clam',
                                       message: "What Chefs Want didn't add it to the cart (it isn't in your What Chefs Want order guide)")
    }
    expect(api).to have_received(:delete_draft_items).with('D1')
  end

  it 'passes when every line landed with the right quantity' do
    allow(api).to receive(:get_draft).and_return(
      draft_with(draft_line('18271', 1), draft_line('10407', 2), draft_line('95839', 3))
    )

    expect(scraper.verify_cart_matches!(order_items)).to be(true)
    expect(api).not_to have_received(:delete_draft_items)
  end

  it 'matches a guide SKU that is a variant of the multi-unit product the draft holds' do
    allow(api).to receive(:get_draft).and_return(
      draft_with(draft_line('M18271', 1, variants: %w[18271 18271LB]), draft_line('10407', 2), draft_line('95839', 3))
    )

    expect(scraper.verify_cart_matches!(order_items)).to be(true)
  end

  it 'stops for review when a quantity differs' do
    allow(api).to receive(:get_draft).and_return(
      draft_with(draft_line('18271', 1), draft_line('10407', 1), draft_line('95839', 3))
    )

    expect { scraper.verify_cart_matches!(order_items) }
      .to raise_error(Scrapers::BaseScraper::CartMismatchError, /doesn't match the order/)
  end

  it 'stops for review when the draft has a line we did not order' do
    allow(api).to receive(:get_draft).and_return(
      draft_with(draft_line('18271', 1), draft_line('10407', 2), draft_line('95839', 3), draft_line('77777', 1))
    )

    expect { scraper.verify_cart_matches!(order_items) }.to raise_error(Scrapers::BaseScraper::CartMismatchError)
  end

  it 'fails closed when the draft cannot be read back' do
    allow(api).to receive(:get_draft).and_return(nil)

    expect { scraper.verify_cart_matches!(order_items) }
      .to raise_error(Scrapers::BaseScraper::ScrapingError, /Couldn't read the What Chefs Want cart back/)
  end

  describe '#checkout confirmation' do
    before do
      allow(api).to receive(:get_draft).and_return(draft_with(draft_line('18271', 1)))
      allow(api).to receive(:get_order_minimum).and_return({})
    end

    it "uses WCW's order id" do
      allow(api).to receive(:submit_order).and_return('data' => { 'CreateNewOrderMutation' => { 'id' => '1180751993', 'total' => { 'money' => '107.90' } } })

      expect(scraper.checkout(dry_run: false)).to include(confirmation_number: '1180751993')
    end

    it 'never makes up a "WCW-<timestamp>" confirmation' do
      allow(api).to receive(:submit_order).and_return('data' => { 'CreateNewOrderMutation' => { 'id' => nil, 'total' => { 'money' => '107.90' } } })

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError, /Check What Chefs Want before reordering/)
    end
  end
end
