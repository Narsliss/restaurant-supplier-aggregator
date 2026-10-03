require 'rails_helper'

# Regression coverage for the Chef's Warehouse cart-safety guards added after a
# real order shipped a $466.32 case of pistachios (SKU NP120) that the chef had
# removed. Root cause: CW's server-side cart accumulated an orphaned line across
# a failed-retry storm, `delete_cart` reported success without emptying it, and
# `checkout` submitted the whole cart with no reconciliation against the order.
RSpec.describe Scrapers::ChefsWarehouseScraper do
  let(:supplier)   { create(:supplier, scraper_class: 'Scrapers::ChefsWarehouseScraper') }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:scraper)    { described_class.new(credential) }
  let(:api)        { instance_double(Scrapers::ChefsWarehouseApi, ensure_session!: nil) }

  before { allow(scraper).to receive(:api_client).and_return(api) }

  # Build a CW cart payload with product lines nested the way the live API does
  # (cartGroups → subCarts → lines). The extractor recurses, so the exact
  # container keys don't matter — only that lines carry a code + quantity.
  def cart_with(*lines)
    { 'cartGroups' => [{ 'subCarts' => [{ 'lines' => lines }] }],
      'summary' => { 'totals' => { 'totalDecimal' => 0 } } }
  end

  def line(code:, qty:, id: 1, uom: 'Case')
    { 'id' => id, 'code' => code, 'unitOfMeasure' => uom, 'quantity' => qty.to_f }
  end

  def empty_cart
    { 'cartGroups' => [], 'oosLines' => [], 'summary' => { 'totals' => {} } }
  end

  describe '#verify_cart_matches!' do
    let(:expected) do
      [{ sku: 'GF210', quantity: 1 }, { sku: 'QG16686', quantity: 2 }]
    end

    it 'passes silently when the cart exactly matches the order' do
      allow(api).to receive(:get_cart).and_return(
        cart_with(line(code: 'JDE_GF210', qty: 1, id: 10),
                  line(code: 'JDE_QG16686', qty: 2, id: 11))
      )

      expect(scraper.verify_cart_matches!(expected)).to be(true)
    end

    it 'normalizes JDE_ prefixes and -800001 business-unit suffixes when matching' do
      allow(api).to receive(:get_cart).and_return(
        cart_with(line(code: 'JDE_GF210-800001', qty: 1, id: 10),
                  line(code: 'JDE_QG16686-800001', qty: 2, id: 11))
      )

      expect { scraper.verify_cart_matches!(expected) }.not_to raise_error
    end

    # THE incident: a line in the cart that the order does not contain.
    it 'raises CartMismatchError with an extra_in_cart discrepancy for an orphaned line' do
      allow(api).to receive(:get_cart).and_return(
        cart_with(line(code: 'JDE_GF210', qty: 1, id: 10),
                  line(code: 'JDE_QG16686', qty: 2, id: 11),
                  line(code: 'JDE_NP120', qty: 1, id: 12)) # <- the removed pistachios, still in cart
      )

      expect { scraper.verify_cart_matches!(expected) }
        .to raise_error(Scrapers::BaseScraper::CartMismatchError) { |e|
          expect(e.discrepancies).to include(hash_including(type: 'extra_in_cart', sku: 'NP120'))
        }
    end

    it 'raises when an ordered item is missing from the cart' do
      allow(api).to receive(:get_cart).and_return(cart_with(line(code: 'JDE_GF210', qty: 1, id: 10)))

      expect { scraper.verify_cart_matches!(expected) }
        .to raise_error(Scrapers::BaseScraper::CartMismatchError) { |e|
          expect(e.discrepancies).to include(hash_including(type: 'missing_from_cart', sku: 'QG16686'))
        }
    end

    it 'raises when a quantity does not match' do
      allow(api).to receive(:get_cart).and_return(
        cart_with(line(code: 'JDE_GF210', qty: 1, id: 10),
                  line(code: 'JDE_QG16686', qty: 5, id: 11)) # ordered 2, cart has 5
      )

      expect { scraper.verify_cart_matches!(expected) }
        .to raise_error(Scrapers::BaseScraper::CartMismatchError) { |e|
          expect(e.discrepancies).to include(
            hash_including(type: 'quantity_mismatch', sku: 'QG16686', cart_qty: 5, expected_qty: 2)
          )
        }
    end

    # Piece-vs-case protection (generalizes the fix to ALL items, not just the
    # phantom scenario): a PC order that lands in the cart as a Case would be
    # charged the case price. Guard catches it.
    it 'raises uom_mismatch when a piece order is a case in the cart (PC charged as case price)' do
      allow(api).to receive(:get_cart).and_return(cart_with(line(code: 'JDE_NP120', qty: 1, id: 12, uom: 'Case')))

      expect { scraper.verify_cart_matches!([{ sku: 'NP120', quantity: 1, uom: 'PC' }]) }
        .to raise_error(Scrapers::BaseScraper::CartMismatchError) { |e|
          expect(e.discrepancies).to include(
            hash_including(type: 'uom_mismatch', sku: 'NP120', expected_uom: :piece, cart_uom: :case)
          )
        }
    end

    it 'passes when a piece order is correctly a piece in the cart' do
      allow(api).to receive(:get_cart).and_return(cart_with(line(code: 'JDE_NP120', qty: 1, id: 12, uom: 'Piece')))

      expect { scraper.verify_cart_matches!([{ sku: 'NP120', quantity: 1, uom: 'PC' }]) }.not_to raise_error
    end

    it 'does not flag UOM for a normal case order (uom nil) that is a case in the cart' do
      allow(api).to receive(:get_cart).and_return(cart_with(line(code: 'JDE_NP120', qty: 1, id: 12, uom: 'Case')))

      expect { scraper.verify_cart_matches!([{ sku: 'NP120', quantity: 1, uom: nil }]) }.not_to raise_error
    end

    it 'does not flag UOM for variable-weight / unknown cart UOMs' do
      allow(api).to receive(:get_cart).and_return(cart_with(line(code: 'JDE_NP120', qty: 1, id: 12, uom: 'LB')))

      expect { scraper.verify_cart_matches!([{ sku: 'NP120', quantity: 1, uom: 'PC' }]) }.not_to raise_error
    end
  end

  describe '#clear_cart' do
    it 'succeeds without removing anything when delete_cart empties the cart' do
      allow(api).to receive(:delete_cart)
      allow(api).to receive(:get_cart).and_return(empty_cart)
      allow(api).to receive(:remove_cart_item)

      expect { scraper.clear_cart }.not_to raise_error
      expect(api).to have_received(:delete_cart)
      expect(api).not_to have_received(:remove_cart_item)
    end

    it 'removes leftover lines individually when delete_cart reports success but does not empty' do
      allow(api).to receive(:delete_cart)
      # delete_cart "succeeded" but a line remains; after individual removal it's empty.
      allow(api).to receive(:get_cart).and_return(
        cart_with(line(code: 'JDE_NP120', qty: 1, id: 99)),
        empty_cart
      )
      allow(api).to receive(:remove_cart_item)

      expect { scraper.clear_cart }.not_to raise_error
      expect(api).to have_received(:remove_cart_item).with(99)
    end

    # Regression for Bug B: never silently proceed on a cart that won't empty.
    it 'raises ScrapingError (fails closed) when the cart still has lines after removal attempts' do
      allow(api).to receive(:delete_cart)
      allow(api).to receive(:get_cart).and_return(cart_with(line(code: 'JDE_NP120', qty: 1, id: 99)))
      allow(api).to receive(:remove_cart_item) # removal doesn't actually work

      expect { scraper.clear_cart }.to raise_error(Scrapers::BaseScraper::ScrapingError, /could not be emptied/)
    end

    it 'still fails closed even if delete_cart itself raises' do
      allow(api).to receive(:delete_cart).and_raise(StandardError, 'boom')
      allow(api).to receive(:get_cart).and_return(cart_with(line(code: 'JDE_NP120', qty: 1, id: 99)))
      allow(api).to receive(:remove_cart_item)

      expect { scraper.clear_cart }.to raise_error(Scrapers::BaseScraper::ScrapingError)
    end
  end

  # Regression — Sep 27 2026 (order #331). CW's refresh-prices call, made by
  # checkout right before submit, silently dropped Oregano (QG9804). The
  # reconciliation gate had already passed, so the order would have been
  # submitted without it while our order page still listed it.
  describe '#checkout re-checks the cart after the price refresh' do
    let(:expected) do
      [{ sku: 'QG34100', name: 'Sour Cream', quantity: 1 },
       { sku: 'QG9804', name: 'Oregano', quantity: 1 }]
    end
    let(:full_cart) do
      cart_with(line(code: 'JDE_QG34100-800001', qty: 1, id: 1),
                line(code: 'JDE_QG9804-800001', qty: 1, id: 2))
    end

    def priced(cart, count:)
      cart.merge('summary' => { 'itemCount' => count, 'totals' => { 'totalDecimal' => 1288.72 } })
    end

    before do
      allow(api).to receive(:refresh_cart_prices)
      allow(api).to receive(:validate_cart).and_return({})
      # Shape of CW's real cart/submit success (order #331): the number is
      # nested under confirmedOrders; the top-level orderNumber is nil.
      allow(api).to receive(:submit_cart).and_return(
        { 'success' => true, 'orderNumber' => nil, 'validationMessages' => [],
          'confirmedOrders' => [{ 'orderNumber' => 'TCW1', 'businessUnitId' => '800001' }] }
      )
      allow(api).to receive(:delete_cart)
      allow(api).to receive(:remove_cart_item)
    end

    it 'names the dropped item, empties the cart and never submits' do
      after_refresh = priced(cart_with(line(code: 'JDE_QG34100-800001', qty: 1, id: 1)), count: 1)
      allow(api).to receive(:get_cart).and_return(full_cart, after_refresh, empty_cart)

      scraper.verify_cart_matches!(expected)

      expect { scraper.checkout(dry_run: false) }.to raise_error(Scrapers::BaseScraper::ItemUnavailableError) { |e|
        expect(e.items).to eq([{ sku: 'QG9804', name: 'Oregano',
                                 message: "Chef's Warehouse removed this item from the cart at checkout" }])
      }
      expect(api).to have_received(:delete_cart)
      expect(api).not_to have_received(:submit_cart)
    end

    it 'fails closed as a mismatch when the refresh changes a quantity' do
      after_refresh = priced(cart_with(line(code: 'JDE_QG34100-800001', qty: 2, id: 1),
                                       line(code: 'JDE_QG9804-800001', qty: 1, id: 2)), count: 3)
      allow(api).to receive(:get_cart).and_return(full_cart, after_refresh, empty_cart)

      scraper.verify_cart_matches!(expected)

      expect { scraper.checkout(dry_run: false) }.to raise_error(Scrapers::BaseScraper::CartMismatchError, /price refresh/)
      expect(api).not_to have_received(:submit_cart)
    end

    it 'submits when the cart still matches after the refresh' do
      allow(api).to receive(:get_cart).and_return(full_cart, priced(full_cart, count: 2))

      scraper.verify_cart_matches!(expected)

      expect(scraper.checkout(dry_run: false)[:confirmation_number]).to eq('TCW1')
      expect(api).to have_received(:submit_cart).with(dry_run: false)
    end

    it 'runs the same check on a dry run' do
      after_refresh = priced(cart_with(line(code: 'JDE_QG34100-800001', qty: 1, id: 1)), count: 1)
      allow(api).to receive(:get_cart).and_return(full_cart, after_refresh, empty_cart)

      scraper.verify_cart_matches!(expected)

      expect { scraper.checkout(dry_run: true) }.to raise_error(Scrapers::BaseScraper::ItemUnavailableError)
    end
  end

  # Oct 2026: 20 of 22 live CW orders were recorded under a made-up
  # "API-<timestamp>" confirmation because we read the top-level orderNumber
  # (always nil). A rejected submit looked identical to a placed order.
  describe '#checkout confirmation number' do
    let(:expected) { [{ sku: 'QG34100', name: 'Sour Cream', quantity: 1 }] }
    let(:full_cart) do
      cart_with(line(code: 'JDE_QG34100-800001', qty: 1, id: 1))
        .merge('summary' => { 'itemCount' => 1, 'totals' => { 'totalDecimal' => 450.0 } })
    end

    before do
      allow(api).to receive(:refresh_cart_prices)
      allow(api).to receive(:validate_cart).and_return({})
      allow(api).to receive(:get_cart).and_return(full_cart)
      scraper.verify_cart_matches!(expected)
    end

    it "uses CW's nested order number" do
      allow(api).to receive(:submit_cart).and_return(
        { 'success' => true, 'orderNumber' => nil,
          'confirmedOrders' => [{ 'orderNumber' => 'TCW9912239489' }] }
      )

      expect(scraper.checkout(dry_run: false)[:confirmation_number]).to eq('TCW9912239489')
    end

    it 'joins every order number when CW splits the cart' do
      allow(api).to receive(:submit_cart).and_return(
        { 'success' => true, 'confirmedOrders' => [{ 'orderNumber' => 'TCW1' }, { 'orderNumber' => 'TCW2' }] }
      )

      expect(scraper.checkout(dry_run: false)[:confirmation_number]).to eq('TCW1, TCW2')
    end

    it 'fails as not placed when CW says success: false' do
      allow(api).to receive(:submit_cart).and_return(
        { 'success' => false, 'confirmedOrders' => [], 'validationMessages' => [{ 'message' => 'Cutoff passed' }] }
      )

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, /rejected the order: Cutoff passed. Nothing was placed/)
    end

    it 'fails as not placed when submit returns nothing and the items are still in the cart' do
      allow(api).to receive(:submit_cart).and_return(nil)

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, /still in the cart/)
    end

    it 'raises OrderUnconfirmedError when submit times out and the cart is empty' do
      allow(api).to receive(:submit_cart).and_raise(Net::ReadTimeout)
      allow(api).to receive(:get_cart).and_return(full_cart, empty_cart)

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError, /Check Chef's Warehouse before reordering/)
    end

    it 'never returns a made-up API-<timestamp> confirmation' do
      allow(api).to receive(:submit_cart).and_return({ 'success' => true, 'confirmedOrders' => [] })
      allow(api).to receive(:get_cart).and_return(full_cart, empty_cart)

      expect { scraper.checkout(dry_run: false) }.to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError)
    end
  end

  # Deep catalog crawl must paginate a category past the old 100-item cap.
  describe '#scrape_catalog_deep' do
    before do
      allow(scraper).to receive(:rate_limit_delay)
      allow(scraper).to receive(:discover_leaf_categories).and_return([{ path: '/seafood', name: 'Seafood' }])
      allow(scraper).to receive(:format_catalog_product) { |p, _n| { supplier_sku: p[:code] } }
    end

    it 'paginates via page_token past the old 100-item cap until the token runs out' do
      allow(api).to receive(:search_category) do |_path, **kw|
        case kw[:page_token]
        when '' then { products: Array.new(50) { |i| { code: "A#{i}" } }, page_token: 't1' }
        when 't1' then { products: Array.new(50) { |i| { code: "B#{i}" } }, page_token: 't2' }
        when 't2' then { products: Array.new(50) { |i| { code: "C#{i}" } }, page_token: '' } # 150 total
        end
      end

      collected = []
      scraper.scrape_catalog_deep { |batch| collected.concat(batch) }

      expect(collected.size).to eq(150) # old cap would have stopped at 100
    end
  end
end
