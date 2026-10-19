require 'rails_helper'

# US Foods order placement checks (Oct 2026, plan Phase 1). Until then US
# Foods had no line check: add_to_cart always reported nothing failed, a failed
# cart write fell back to our own copy of the order, and any answer from
# submit counted as placed. Each of those could ship a chef a short order.
RSpec.describe Scrapers::UsFoodsScraper do
  let(:supplier)   { create(:supplier, :two_fa) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:scraper)    { described_class.new(credential) }
  let(:api)        { instance_double(Scrapers::UsFoodsApi, ensure_session!: nil) }

  before { allow(scraper).to receive(:api_client).and_return(api) }

  # US Foods' order shape (order-domain-api): lines carry productNumber,
  # unitsOrdered (cases) and eachesOrdered.
  def usf_order(id: 'ord-1', status: 'IN_PROGRESS', lines: { 5_034_236 => 2 }, eaches: {})
    { 'orderId' => id, 'orderStatus' => status, 'requestedDeliveryDate' => '2026-10-20T00:00:00.000Z',
      'totalUnits' => lines.values.sum,
      'orderItems' => lines.map { |pn, q| { 'productNumber' => pn, 'unitsOrdered' => q, 'eachesOrdered' => eaches[pn] || 0 } } }
  end

  let(:expected) { [{ sku: '5034236', name: 'Chuck Roll', quantity: 2, uom: nil }] }

  describe '#add_to_cart' do
    it 'stops a piece (PC) line before touching US Foods — it would go out as cases' do
      expect(api).not_to receive(:get_or_create_order)

      result = scraper.add_to_cart([{ sku: '5034236', name: 'Chuck Roll', quantity: 3, uom: 'PC' }])

      expect(result[:failed]).to eq([{ sku: '5034236', name: 'Chuck Roll',
                                       error: "US Foods piece ordering isn't set up in EnPlace yet — order it by the case" }])
    end

    it 'stops the order when US Foods does not take the cart update (no fallback to our copy)' do
      allow(api).to receive(:get_or_create_order).and_return(usf_order(lines: {}))
      allow(api).to receive(:fetch_product_details).and_return([])
      allow(api).to receive(:add_items_to_order).and_return(nil)

      expect { scraper.add_to_cart(expected) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, /didn't accept the cart update/)
    end
  end

  describe '#clear_cart' do
    it 'fails closed when the clear does not take' do
      allow(api).to receive(:get_orders).and_return([usf_order])
      allow(api).to receive(:clear_order).and_return(nil)

      expect { scraper.clear_cart }.to raise_error(Scrapers::BaseScraper::ScrapingError, /could not be emptied/)
    end

    it 'fails closed when lines are still there after the clear' do
      allow(api).to receive(:get_orders).and_return([usf_order])
      allow(api).to receive(:clear_order).and_return(usf_order)

      expect { scraper.clear_cart }.to raise_error(Scrapers::BaseScraper::ScrapingError, /could not be emptied/)
    end

    it 'fails closed when the cart cannot be read' do
      allow(api).to receive(:get_orders).and_return(nil)

      expect { scraper.clear_cart }.to raise_error(Scrapers::BaseScraper::ScrapingError, /Couldn't read the US Foods cart/)
    end

    it 'passes when the clear empties the order' do
      allow(api).to receive(:get_orders).and_return([usf_order])
      allow(api).to receive(:clear_order).and_return(usf_order(lines: {}))

      expect { scraper.clear_cart }.not_to raise_error
    end
  end

  describe '#verify_cart_matches!' do
    before do
      scraper.instance_variable_set(:@last_usf_order, usf_order)
      allow(api).to receive(:clear_order).and_return(usf_order(lines: {}))
    end

    it 'passes and hands checkout US Foods’ own copy of the order' do
      fresh = usf_order
      allow(api).to receive(:get_orders).and_return([fresh, usf_order(id: 'other', status: 'SUBMITTED')])

      expect(scraper.verify_cart_matches!(expected)).to be(true)
      expect(scraper.instance_variable_get(:@last_usf_order)).to equal(fresh)
    end

    it 'stops, names the missing line and empties the cart when US Foods dropped it' do
      allow(api).to receive(:get_orders).and_return([usf_order(lines: { 5_034_236 => 2 })])
      two_lines = expected + [{ sku: '6554265', name: 'Beef', quantity: 1 }]

      expect { scraper.verify_cart_matches!(two_lines) }.to raise_error(Scrapers::BaseScraper::CartMismatchError) { |e|
        expect(e.discrepancies).to eq([{ type: 'missing_from_cart', sku: '6554265', expected_qty: 1 }])
      }
      expect(api).to have_received(:clear_order)
    end

    it 'stops on a changed quantity' do
      allow(api).to receive(:get_orders).and_return([usf_order(lines: { 5_034_236 => 1 })])

      expect { scraper.verify_cart_matches!(expected) }.to raise_error(Scrapers::BaseScraper::CartMismatchError) { |e|
        expect(e.discrepancies).to eq([{ type: 'quantity_mismatch', sku: '5034236', cart_qty: 1, expected_qty: 2 }])
      }
    end

    it 'stops on an extra line' do
      allow(api).to receive(:get_orders).and_return([usf_order(lines: { 5_034_236 => 2, 4_336_327 => 1 })])

      expect { scraper.verify_cart_matches!(expected) }.to raise_error(Scrapers::BaseScraper::CartMismatchError) { |e|
        expect(e.discrepancies).to eq([{ type: 'extra_in_cart', sku: '4336327', cart_qty: 1 }])
      }
    end

    it 'stops when a case line turned into eaches' do
      allow(api).to receive(:get_orders).and_return([usf_order(lines: { 5_034_236 => 0 }, eaches: { 5_034_236 => 2 })])

      expect { scraper.verify_cart_matches!(expected) }.to raise_error(Scrapers::BaseScraper::CartMismatchError) { |e|
        expect(e.discrepancies.first).to include(type: 'uom_mismatch', sku: '5034236')
      }
    end

    it 'stops (nothing submitted) when the order cannot be read back' do
      allow(api).to receive(:get_orders).and_return([], [usf_order])

      expect { scraper.verify_cart_matches!(expected) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, /Couldn't read the US Foods order back/)
    end

    # D1 (Carmin, Oct 19 2026): our cached "out" no longer stops a US Foods
    # order at submit; the price check warns from live stock instead.
    it 'confirms its lines, so the cached stock flag no longer stops the order' do
      expect(scraper.confirms_lines_before_submit?).to be(true)
    end
  end

  # The price check reads US Foods' live warehouse stock from the products
  # call's inventory block (shape probed live Oct 19 2026).
  describe '#scrape_prices live stock' do
    def product(pn, inventory)
      { 'productNumber' => pn, 'summary' => { 'productDescTxtl' => 'Item' }, 'inventory' => inventory }
    end

    def stock_for(inventory, uom: nil)
      allow(api).to receive(:fetch_products).and_return([product(5_034_236, inventory)])
      allow(api).to receive(:fetch_prices).and_return({ 5_034_236 => { case_price: 50.0, error_number: 0 } })
      scraper.scrape_prices([{ sku: '5034236', uom: uom }]).first[:in_stock]
    end

    it 'is in stock with cases available after reserves' do
      expect(stock_for({ 'productType' => 'R', 'casesOnHand' => 14, 'casesOnReserve' => 2, 'casesWaitlistReserve' => 0 })).to be(true)
    end

    it 'is out when every case on hand is reserved' do
      expect(stock_for({ 'productType' => 'R', 'casesOnHand' => 5, 'casesOnReserve' => 5, 'casesWaitlistReserve' => 0 })).to be(false)
    end

    it 'counts eaches for a piece line' do
      expect(stock_for({ 'productType' => 'R', 'casesOnHand' => 9, 'eachOnHand' => 0, 'eachOnReserve' => 0 }, uom: 'PC')).to be(false)
    end

    it 'does not guess for items that are not regular warehouse stock' do
      expect(stock_for({ 'productType' => 'D', 'casesOnHand' => 0 })).to be_nil
    end

    it 'does not guess when US Foods returned no product (was read as "out")' do
      allow(api).to receive(:fetch_products).and_return([])
      allow(api).to receive(:fetch_prices).and_return({})

      expect(scraper.scrape_prices([{ sku: '5034236', uom: nil }]).first[:in_stock]).to be_nil
    end

    it 'reports live stock and warns rather than blocks' do
      expect(described_class.reports_live_stock?).to be(true)
      expect(described_class.warn_only_out_of_stock?).to be(true)
    end
  end

  describe '#checkout' do
    let(:order) { usf_order(lines: { 5_034_236 => 2 }) }

    before do
      scraper.instance_variable_set(:@last_usf_order, order)
      scraper.instance_variable_set(:@expected_cart_items, expected)
      allow(api).to receive(:fetch_prices).and_return({ 5_034_236 => { case_price: 200.0, error_number: 0 } })
      allow(api).to receive(:clear_order).and_return(usf_order(lines: {}))
      allow(api).to receive(:get_orders).and_return([])
      allow(api).to receive(:get_recent_orders).and_return([])
    end

    # The shape of a real successful submit (order 482, Oct 19 2026).
    it "confirms with US Foods' order id when the submit answers SUBMITTING without a number yet" do
      allow(api).to receive(:submit_order).and_return({ 'orderId' => 'ord-1', 'orderStatus' => 'SUBMITTING' })

      expect(scraper.checkout(dry_run: false)[:confirmation_number]).to eq('ord-1')
    end

    it 'uses the US Foods order number when the submit already has one' do
      allow(api).to receive(:submit_order)
        .and_return({ 'orderId' => 'ord-1', 'orderStatus' => 'SUBMITTED', 'tandemOrderNumber' => '648653' })

      expect(scraper.checkout(dry_run: false)[:confirmation_number]).to eq('648653')
    end

    it 'says "not placed, safe to retry" when the order is still in the cart after a failed submit' do
      allow(api).to receive(:submit_order).and_raise(Net::ReadTimeout)
      allow(api).to receive(:get_orders).and_return([order])

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, /still in the cart\. Nothing was placed/)
    end

    it 'confirms from US Foods’ records when the submit timed out but the order went through' do
      allow(api).to receive(:submit_order).and_raise(Net::ReadTimeout)
      allow(api).to receive(:get_recent_orders)
        .and_return([{ 'orderId' => 'ord-1', 'orderStatus' => 'SUBMITTED', 'tandemOrderNumber' => '777' }])

      expect(scraper.checkout(dry_run: false)[:confirmation_number]).to eq('777')
    end

    it 'parks the order as unconfirmed when US Foods can say neither' do
      allow(api).to receive(:submit_order).and_return(nil)

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError, /Check US Foods before reordering/)
    end

    it "never takes another order's answer as ours" do
      allow(api).to receive(:submit_order).and_return({ 'orderId' => 'someone-else', 'orderStatus' => 'SUBMITTED' })
      allow(api).to receive(:get_orders).and_return([order])

      expect { scraper.checkout(dry_run: false) }.to raise_error(Scrapers::BaseScraper::ScrapingError, /still in the cart/)
    end

    it 'never submits an order that is not the open cart' do
      scraper.instance_variable_set(:@last_usf_order, usf_order(status: 'SUBMITTED'))
      expect(api).not_to receive(:submit_order)

      expect { scraper.checkout(dry_run: false) }.to raise_error(Scrapers::BaseScraper::ScrapingError, /isn't an open cart/)
    end

    it 'names an item US Foods discontinued instead of shipping it at $0, and submits nothing' do
      allow(api).to receive(:fetch_prices).and_return({ 5_034_236 => { case_price: 0.0, error_number: 1104 } })
      allow(api).to receive(:get_orders).and_return([order]) # the cart to empty
      expect(api).not_to receive(:submit_order)

      expect { scraper.checkout(dry_run: false) }.to raise_error(Scrapers::BaseScraper::ItemUnavailableError) { |e|
        expect(e.items).to eq([{ sku: '5034236', name: 'Chuck Roll', message: 'US Foods has discontinued this item' }])
      }
      expect(api).to have_received(:clear_order)
    end

    it 'runs the same price check on a dry run' do
      allow(api).to receive(:fetch_prices).and_return({ 5_034_236 => { case_price: 0.0, error_number: 1106 } })

      expect { scraper.checkout(dry_run: true) }.to raise_error(Scrapers::BaseScraper::ItemUnavailableError)
    end

    it 'stops when US Foods returns no prices at all' do
      allow(api).to receive(:fetch_prices).and_return({})
      expect(api).not_to receive(:submit_order)

      expect { scraper.checkout(dry_run: false) }.to raise_error(Scrapers::BaseScraper::ScrapingError, /Couldn't get US Foods prices/)
    end
  end
end
