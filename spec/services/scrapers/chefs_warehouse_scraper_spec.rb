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

    before do
      allow(api).to receive(:delete_cart)
      allow(api).to receive(:remove_cart_item)
    end

    # Order 483 (Oct 19 2026): the order stopped but D'oro's CW cart kept
    # $1,402.15 of lines on Chef's Warehouse's website.
    it 'empties the cart before stopping the order' do
      allow(api).to receive(:get_cart).and_return(cart_with(line(code: 'JDE_GF210', qty: 1, id: 10)), empty_cart)

      expect { scraper.verify_cart_matches!(expected) }.to raise_error(Scrapers::BaseScraper::CartMismatchError)
      expect(api).to have_received(:delete_cart)
    end

    it 'still stops the order when the cart will not empty' do
      allow(api).to receive(:get_cart).and_return(cart_with(line(code: 'JDE_GF210', qty: 1, id: 10)))

      expect { scraper.verify_cart_matches!(expected) }.to raise_error(Scrapers::BaseScraper::CartMismatchError)
    end

    it 'leaves a matching cart alone' do
      allow(api).to receive(:get_cart).and_return(
        cart_with(line(code: 'JDE_GF210', qty: 1, id: 10), line(code: 'JDE_QG16686', qty: 2, id: 11))
      )

      scraper.verify_cart_matches!(expected)

      expect(api).not_to have_received(:delete_cart)
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

  # Regression — order #386 (Oct 1 2026). Juice Lemon Real (QG80027A) wasn't in
  # the chef's CW order guide, so add_to_cart dropped it as "Not in order
  # guide" — 9 items across 6 orders since June. CW sells it to her account:
  # live Oct 3, cart/add with JDE_QG80027A-800001 put 1 case at $45.40.
  describe '#add_to_cart items outside the order guide' do
    let(:guide) do
      { 'GO135' => { variant_code: 'JDE_GO135-800001', variant_metadata: { 'stockingType' => 'S' },
                     business_unit_id: '800001', stocking_type: 'S', vendor_id: 'V9', uom: 'CS' } }
    end
    let(:items) do
      [{ sku: 'GO135', name: 'Olive Oil', quantity: 1 },
       { sku: 'QG80027A', name: 'Juice Lemon Real', quantity: 2 }]
    end

    # fetch_prices answers only for the codes CW prices (live shape: a
    # 133002 item gets nothing back under -800001).
    def prices_for(*codes)
      codes.map { |c| { variant_code: c, primary_price: 45.4, primary_uom: 'CS', restricted: false } }
    end

    before do
      allow(scraper).to receive(:load_order_guide_items).and_return(guide)
      allow(api).to receive(:set_delivery_date)
      allow(api).to receive(:fetch_prices).and_return(prices_for('JDE_QG80027A-800001'))
      allow(api).to receive(:delete_cart)
      allow(api).to receive(:remove_cart_item)
      allow(api).to receive(:get_cart).and_return(empty_cart)
    end

    it 'asks the price endpoint about both business units, for off-guide SKUs only' do
      allow(api).to receive(:add_to_cart).and_return({ 'success' => true })

      scraper.add_to_cart(items)

      expect(api).to have_received(:fetch_prices).with(
        [hash_including(code: 'JDE_QG80027A-800001', business_unit_id: '800001'),
         hash_including(code: 'JDE_QG80027A-133002', business_unit_id: '133002')]
      )
    end

    it 'uses business unit 133002 when that is the code CW prices (RWP1178B, live Oct 3)' do
      allow(api).to receive(:fetch_prices).and_return(prices_for('JDE_QG80027A-133002'))
      sent = nil
      allow(api).to receive(:add_to_cart) { |lines| sent = lines; { 'success' => true } }

      scraper.add_to_cart(items)

      expect(sent.last).to include(code: 'JDE_QG80027A-133002', business_unit_id: '133002')
    end

    it "reports an off-guide item CW won't price instead of guessing" do
      allow(api).to receive(:fetch_prices).and_return([])
      sent = nil
      allow(api).to receive(:add_to_cart) { |lines| sent = lines; { 'success' => true } }

      result = scraper.add_to_cart(items)

      expect(sent.map { |l| l[:code] }).to eq(%w[JDE_GO135-800001])
      expect(result[:added]).to eq(1)
      expect(result[:failed]).to eq([{ sku: 'QG80027A', name: 'Juice Lemon Real',
                                         error: "Chef's Warehouse has no price for this item on your account" }])
    end

    it 'says "try again" (not "no price") when the lookup itself fails' do
      allow(api).to receive(:fetch_prices).and_raise(Net::ReadTimeout)
      allow(api).to receive(:add_to_cart).and_return({ 'success' => true })

      result = scraper.add_to_cart(items)

      expect(result[:failed].first[:error]).to match(/try again/)
    end

    it 'treats a restricted price as not orderable' do
      allow(api).to receive(:fetch_prices).and_return(
        [{ variant_code: 'JDE_QG80027A-800001', primary_price: 45.4, restricted: true }]
      )
      allow(api).to receive(:add_to_cart).and_return({ 'success' => true })

      expect(scraper.add_to_cart(items)[:failed].map { |f| f[:sku] }).to eq(['QG80027A'])
    end

    it 'adds the non-guide item by its catalog code instead of dropping it' do
      sent = nil
      allow(api).to receive(:add_to_cart) { |lines| sent = lines; { 'success' => true, 'totalCount' => 3 } }

      result = scraper.add_to_cart(items, delivery_date: Date.new(2026, 10, 2))

      expect(result).to eq(added: 2, failed: [])
      expect(sent.map { |l| l[:code] }).to eq(%w[JDE_GO135-800001 JDE_QG80027A-800001])
      lemon = sent.last
      expect(lemon).to include(quantity: 2, business_unit_id: '800001', stocking_type: 'P', vendor_id: nil, uom: 'CS')
    end

    it 'still uses the order guide metadata for guide items' do
      sent = nil
      allow(api).to receive(:add_to_cart) { |lines| sent = lines; { 'success' => true } }

      scraper.add_to_cart(items)

      expect(sent.first).to include(metadata: { 'stockingType' => 'S' }, vendor_id: 'V9', stocking_type: 'S')
    end

    it 'stops the order (cart mismatch) when CW quietly drops the non-guide line' do
      allow(api).to receive(:add_to_cart).and_return({ 'success' => true })
      scraper.add_to_cart(items)
      allow(api).to receive(:get_cart).and_return(cart_with(line(code: 'JDE_GO135-800001', qty: 1)))

      expect { scraper.verify_cart_matches!(items) }
        .to raise_error(Scrapers::BaseScraper::CartMismatchError)
    end

    it "empties the cart when an item can't go in, since the order will stop" do
      allow(api).to receive(:fetch_prices).and_return([])
      allow(api).to receive(:add_to_cart).and_return({ 'success' => true })

      scraper.add_to_cart(items, delivery_date: Date.new(2026, 10, 2))

      expect(api).to have_received(:delete_cart)
      expect(api).not_to have_received(:set_delivery_date)
    end
  end

  # Regression — order 483 (Oct 19 2026, D'oro). cart/add answered
  #   {"totalCount"=>29, "success"=>true,
  #    "validationMessages"=>["Out of stock - (NW101B) Walnut Halves"]}
  # and left the walnuts out. We read success: true as "all added", so the
  # cart check stopped the order as "a leftover item from a previous attempt"
  # three times, and the chef never learned which item.
  describe '#add_to_cart when CW refuses a line in validationMessages' do
    let(:guide) do
      { 'NW101B' => { variant_code: 'JDE_NW101B-800001', variant_metadata: {}, business_unit_id: '800001' },
        'GO135' => { variant_code: 'JDE_GO135-800001', variant_metadata: {}, business_unit_id: '800001' } }
    end
    let(:items) do
      [{ sku: 'NW101B', name: 'Walnut Halves', quantity: 1 },
       { sku: 'GO135', name: 'Olive Oil', quantity: 1 }]
    end

    def cw_answers(*messages)
      allow(api).to receive(:add_to_cart)
        .and_return({ 'totalCount' => 29, 'success' => true, 'validationMessages' => messages })
    end

    before do
      allow(scraper).to receive(:load_order_guide_items).and_return(guide)
      allow(api).to receive(:set_delivery_date)
      allow(api).to receive(:delete_cart)
      allow(api).to receive(:remove_cart_item)
      allow(api).to receive(:get_cart).and_return(empty_cart)
    end

    it "reports the line as failed with CW's reason" do
      cw_answers('Out of stock - (NW101B) Walnut Halves')

      expect(scraper.add_to_cart(items)).to eq(
        added: 1, failed: [{ sku: 'NW101B', name: 'Walnut Halves', error: 'Out of stock' }]
      )
    end

    it 'empties the cart and skips the delivery date, since the order will stop' do
      cw_answers('Out of stock - (NW101B) Walnut Halves')

      scraper.add_to_cart(items, delivery_date: Date.new(2026, 10, 21))

      expect(api).to have_received(:delete_cart)
      expect(api).not_to have_received(:set_delivery_date)
    end

    it 'matches the line however CW writes the code' do
      cw_answers('Out of stock - (JDE_nw101b-800001) Walnut Halves')

      expect(scraper.add_to_cart(items)[:failed].map { |f| f[:sku] }).to eq(['NW101B'])
    end

    it "keeps CW's whole text when the wording is different" do
      cw_answers('Walnut Halves (NW101B) is no longer sold')

      expect(scraper.add_to_cart(items)[:failed]).to eq(
        [{ sku: 'NW101B', name: 'Walnut Halves', error: 'Walnut Halves (NW101B) is no longer sold' }]
      )
    end

    it "doesn't fail a line for a message that names none of ours" do
      cw_answers('Out of stock - (ZZ999) Something Else', 'Cart updated')

      expect(scraper.add_to_cart(items, delivery_date: Date.new(2026, 10, 21))).to eq(added: 2, failed: [])
      expect(api).not_to have_received(:delete_cart)
      expect(api).to have_received(:set_delivery_date)
    end

    it 'raises ItemUnavailableError naming every line when CW refuses them all' do
      cw_answers('Out of stock - (NW101B) Walnut Halves', 'Out of stock - (GO135) Olive Oil')

      expect { scraper.add_to_cart(items) }.to raise_error(Scrapers::BaseScraper::ItemUnavailableError) { |e|
        expect(e.items.map { |i| i[:name] }).to eq(['Walnut Halves', 'Olive Oil'])
      }
      expect(api).to have_received(:delete_cart)
    end

    it 'names our own lines when CW rejects the whole request' do
      allow(api).to receive(:add_to_cart).and_return({ 'success' => false })

      expect { scraper.add_to_cart(items) }.to raise_error(Scrapers::BaseScraper::ItemUnavailableError) { |e|
        expect(e.items.map { |i| i.slice(:sku, :name) }).to eq(
          [{ sku: 'NW101B', name: 'Walnut Halves' }, { sku: 'GO135', name: 'Olive Oil' }]
        )
      }
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
        .to raise_error(Scrapers::BaseScraper::NotPlacedError, /rejected the order: Cutoff passed. Nothing was placed/)
      expect(scraper.submit_sent?).to be(true)
    end

    # Risk #4, Oct 20 2026: an unanswered submit with the items still in the
    # cart used to say "safe to try again", which could place a second order
    # if CW was still taking the first. The chef checks CW instead.
    it 'parks the order as unconfirmed when submit returns nothing and the items are still in the cart' do
      allow(api).to receive(:submit_cart).and_return(nil)

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError,
                        /still in the Chef's Warehouse cart.*Check Chef's Warehouse before reordering/)
      expect(scraper.submit_sent?).to be(true)
    end

    it 'parks the order as unconfirmed when submit times out and the items are still in the cart' do
      allow(api).to receive(:submit_cart).and_raise(Net::ReadTimeout)

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError, /Check Chef's Warehouse before reordering/)
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

  # Full catalog crawl (the 6 AM import and the weekly deep crawl). Live Oct 19
  # 2026: the next-page token went missing at random on any login, so the
  # "deep" crawl read one page per category (512 of ~15,900 items) and logged
  # complete. Paging by page number up to CW's total worked on every login.
  describe 'full catalog crawl' do
    before do
      allow(scraper).to receive(:rate_limit_delay)
      allow(scraper).to receive(:discover_leaf_categories).and_return([{ path: '/seafood', name: 'Seafood' }])
      allow(scraper).to receive(:format_catalog_product) { |p, _n| { supplier_sku: p[:code] } }
    end

    def pages(total, per = 50)
      allow(api).to receive(:search_category) do |_path, **kw|
        start = kw[:page] * per
        count = [[total - start, per].min, 0].max
        { products: Array.new(count) { |i| { code: "S#{start + i}" } }, total: total, page_token: '' } # no token, like live
      end
    end

    it 'pages by number up to the total even when CW sends no next-page token' do
      pages(150)

      collected = []
      scraper.scrape_catalog_deep { |batch| collected.concat(batch) }

      expect(collected.size).to eq(150)
      expect(scraper.crawl_stats).to include('fetched' => 150, 'expected' => 150, 'short' => [], 'failed' => [])
    end

    it 'is what the 6 AM import runs now (was 100 per category)' do
      pages(320)

      collected = []
      scraper.scrape_catalog(%w[ignored]) { |batch| collected.concat(batch) }

      expect(collected.size).to eq(320)
    end

    it 'reports a short crawl instead of logging it complete' do
      allow(api).to receive(:search_category) do |_path, **kw|
        kw[:page].zero? ? { products: Array.new(50) { |i| { code: "S#{i}" } }, total: 300 } : { products: [], total: 300 }
      end

      scraper.scrape_catalog_deep { |_batch| nil }

      expect(scraper.crawl_stats).to include('fetched' => 50, 'expected' => 300, 'short' => ['Seafood'])
    end

    # Supplies (~19,500 non-food items) stops at the limit, and Carmin keeps
    # it there (Oct 20 2026). That is "capped", not a short crawl.
    it 'reports a category stopped at the page limit as capped, not short' do
      stub_const("#{described_class}::DEEP_MAX_PAGES_PER_CATEGORY", 2)
      pages(300)

      scraper.scrape_catalog_deep { |_batch| nil }

      expect(scraper.crawl_stats).to include('fetched' => 100, 'expected' => 300, 'short' => [],
                                             'capped' => ['Seafood'], 'capped_fetched' => 100, 'capped_expected' => 300)
    end

    it 'never lets the crawl discontinue products' do
      expect(scraper.skip_miss_tracking?).to be(true)
    end

    it "records CW's raw stock count as evidence" do
      allow(scraper).to receive(:format_catalog_product).and_call_original
      formatted = scraper.send(:format_catalog_product, { sku: 'NW101B', name: 'Walnuts', in_stock: false, stock_count: 0.0 }, 'Nuts')
      expect(formatted).to include(in_stock: false, stock_signal: '0.0')
    end
  end
end
