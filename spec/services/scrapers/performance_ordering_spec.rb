require 'rails_helper'

# Stage A ordering framework. The overriding guarantee under test: with cart
# writes disabled (the default), NOTHING is ever written to PFG, and a live
# submit is impossible.
RSpec.describe Scrapers::PerformanceScraper, 'ordering (phase 7 Stage A)' do
  let(:supplier) { create(:supplier) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:scraper) { described_class.new(credential) }
  let(:api) { instance_double(Scrapers::PerformanceApi) }
  let(:oeh) { 'oeh-1' }

  before do
    allow(scraper).to receive(:api_client).and_return(api)
    allow(api).to receive(:ensure_session!)
    allow(api).to receive(:account_context).and_return(order_entry_header_id: oeh, customer_id: 'cust')
  end

  let(:items) { [{ sku: '328740', name: 'TOMATO', quantity: 2 }, { sku: '543638', name: 'OIL', quantity: 1 }] }

  describe '#cart_writes_enabled?' do
    it 'defaults to false (no env)' do
      expect(scraper.cart_writes_enabled?).to be(false)
    end
  end

  describe '#add_to_cart' do
    context 'with cart writes DISABLED (default / Stage A)' do
      it 'makes ZERO writes to PFG and still reports items added' do
        expect(api).not_to receive(:update_order_detail)
        result = scraper.add_to_cart(items)
        expect(result[:added].size).to eq(2)
        expect(result[:failed]).to be_empty
      end
    end

    context 'with cart writes ENABLED (Stage B)' do
      before do
        allow(scraper).to receive(:cart_writes_enabled?).and_return(true)
        allow(api).to receive(:product_by_sku) { |sku| { 'ProductKey' => sku, 'ProductNumber' => sku } }
        allow(api).to receive(:fetch_prices) { |skus| skus.to_h { |s| [s, 10.0] } }
      end

      it 'fetches the product + price and writes each line via update_order_detail' do
        expect(api).to receive(:update_order_detail)
          .with(hash_including(order_entry_header_id: oeh, quantity: 2)).and_return({ 'IsSuccess' => true })
        expect(api).to receive(:update_order_detail)
          .with(hash_including(order_entry_header_id: oeh, quantity: 1)).and_return({ 'IsSuccess' => true })

        result = scraper.add_to_cart(items)
        expect(result[:added].size).to eq(2)
      end

      it 'threads the auto-created draft id from the first add onto later adds' do
        allow(api).to receive(:account_context).and_return(order_entry_header_id: Scrapers::PerformanceApi::NO_ACTIVE_ORDER, customer_id: 'cust')
        # first add against the sentinel returns the real draft id
        expect(api).to receive(:update_order_detail)
          .with(hash_including(order_entry_header_id: Scrapers::PerformanceApi::NO_ACTIVE_ORDER))
          .and_return({ 'IsSuccess' => true, 'ResultObject' => { 'OrderEntryHeaderId' => 'draft-9' } })
        # second add must target the created draft
        expect(api).to receive(:update_order_detail)
          .with(hash_including(order_entry_header_id: 'draft-9'))
          .and_return({ 'IsSuccess' => true, 'ResultObject' => { 'OrderEntryHeaderId' => 'draft-9' } })

        scraper.add_to_cart(items)
        expect(scraper.send(:active_order_id!)).to eq('draft-9')
      end

      it 'collects failures without aborting the batch' do
        allow(api).to receive(:update_order_detail).with(hash_including(quantity: 2))
          .and_return({ 'IsSuccess' => false, 'ErrorMessages' => ['out of stock'] })
        allow(api).to receive(:update_order_detail).with(hash_including(quantity: 1))
          .and_return({ 'IsSuccess' => true })

        result = scraper.add_to_cart(items)
        expect(result[:added].map { |i| i[:sku] }).to eq(['543638'])
        expect(result[:failed].first).to include(sku: '328740', reason: 'out of stock')
      end
    end
  end

  describe '#clear_cart' do
    it 'makes no writes when cart writes are disabled' do
      expect(api).not_to receive(:update_order_detail)
      scraper.clear_cart
    end

    it 'no-ops safely when no lines can be enumerated (line-read unavailable)' do
      allow(scraper).to receive(:cart_writes_enabled?).and_return(true)
      allow(api).to receive(:order_lines).and_return([])
      expect(api).not_to receive(:update_order_detail)
      scraper.clear_cart
    end

    it 'does nothing when there is no open draft (sentinel)' do
      allow(scraper).to receive(:cart_writes_enabled?).and_return(true)
      allow(api).to receive(:account_context).and_return(order_entry_header_id: Scrapers::PerformanceApi::NO_ACTIVE_ORDER, customer_id: 'cust')
      expect(api).not_to receive(:order_lines)
      scraper.clear_cart
    end
  end

  describe '#verify_cart_matches! (totals-based, fails CLOSED)' do
    context 'Stage A (writes disabled)' do
      it 'skips reconciliation and returns true (nothing was written to mismatch)' do
        expect(api).not_to receive(:get_order)
        expect(scraper.verify_cart_matches!(items)).to be(true)
      end
    end

    context 'Stage B (writes enabled)' do
      before { allow(scraper).to receive(:cart_writes_enabled?).and_return(true) }

      it 'passes when the draft totals match (line count + total qty)' do
        allow(api).to receive(:get_order).and_return({ 'TotalLines' => 2, 'TotalQuantity' => 3 })
        expect(scraper.verify_cart_matches!(items)).to be(true)
      end

      it 'fails CLOSED on an orphaned extra line (line count too high)' do
        allow(api).to receive(:get_order).and_return({ 'TotalLines' => 3, 'TotalQuantity' => 3 })
        expect { scraper.verify_cart_matches!(items) }
          .to raise_error(Scrapers::BaseScraper::CartMismatchError, /line_count/)
      end

      it 'fails CLOSED on a total-quantity mismatch' do
        allow(api).to receive(:get_order).and_return({ 'TotalLines' => 2, 'TotalQuantity' => 99 })
        expect { scraper.verify_cart_matches!(items) }
          .to raise_error(Scrapers::BaseScraper::CartMismatchError, /total_quantity/)
      end

      it 'fails CLOSED on a missing item (line count too low)' do
        allow(api).to receive(:get_order).and_return({ 'TotalLines' => 1, 'TotalQuantity' => 2 })
        expect { scraper.verify_cart_matches!(items) }
          .to raise_error(Scrapers::BaseScraper::CartMismatchError, /line_count/)
      end
    end
  end

  describe '#checkout' do
    let(:order) do
      { 'TotalLines' => 2, 'TotalOrderPrice' => 120.0, 'MinimumOrderAmount' => 100.0, 'DeliveryDate' => '2026-09-09T00:00:00' }
    end

    it 'dry-run reads totals and NEVER submits' do
      allow(api).to receive(:get_order).and_return(order)
      expect(api).not_to receive(:submit_order)

      result = scraper.checkout(dry_run: true)
      expect(result[:dry_run]).to be(true)
      expect(result[:total]).to eq(120.0)
      expect(result[:confirmation_number]).to start_with('DRY-RUN-')
    end

    it 'refuses a LIVE submit while cart writes are disabled (double guard)' do
      allow(api).to receive(:get_order).and_return(order)
      expect(api).not_to receive(:submit_order)

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, /PERFORMANCE_CART_WRITES/)
    end

    context 'live with cart writes enabled' do
      before { allow(scraper).to receive(:cart_writes_enabled?).and_return(true) }

      it 'raises on an empty cart' do
        allow(api).to receive(:get_order).and_return(order.merge('TotalLines' => 0))
        expect { scraper.checkout(dry_run: false) }
          .to raise_error(Scrapers::BaseScraper::ScrapingError, /empty/)
      end

      it 'raises OrderMinimumError below the minimum' do
        allow(api).to receive(:get_order).and_return(order.merge('TotalOrderPrice' => 50.0))
        expect { scraper.checkout(dry_run: false) }
          .to raise_error(Scrapers::BaseScraper::OrderMinimumError)
      end

      it 'submits and returns the confirmation number when valid' do
        allow(api).to receive(:get_order).and_return(order)
        expect(api).to receive(:submit_order).with(oeh)
          .and_return({ 'ResultObject' => { 'OrderNumber' => 'PFG-12345' } })

        result = scraper.checkout(dry_run: false)
        expect(result).to include(dry_run: false, confirmation_number: 'PFG-12345', total: 120.0)
      end
    end
  end
end
