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
      before { allow(scraper).to receive(:cart_writes_enabled?).and_return(true) }

      it 'writes each line via update_order_detail' do
        expect(api).to receive(:update_order_detail)
          .with(order_entry_header_id: oeh, product_key: '328740', quantity: 2)
          .and_return({ 'IsSuccess' => true })
        expect(api).to receive(:update_order_detail)
          .with(order_entry_header_id: oeh, product_key: '543638', quantity: 1)
          .and_return({ 'IsSuccess' => true })

        result = scraper.add_to_cart(items)
        expect(result[:added].size).to eq(2)
      end

      it 'collects failures without aborting the batch' do
        allow(api).to receive(:update_order_detail).with(hash_including(product_key: '328740'))
          .and_return({ 'IsSuccess' => false, 'ErrorMessages' => ['out of stock'] })
        allow(api).to receive(:update_order_detail).with(hash_including(product_key: '543638'))
          .and_return({ 'IsSuccess' => true })

        result = scraper.add_to_cart(items)
        expect(result[:added].map { |i| i[:sku] }).to eq(['543638'])
        expect(result[:failed].first).to include(sku: '328740', reason: 'out of stock')
      end
    end
  end

  describe '#clear_cart' do
    it 'makes no writes when cart writes are disabled' do
      expect(api).not_to receive(:order_lines)
      expect(api).not_to receive(:update_order_detail)
      scraper.clear_cart
    end

    it 'zeroes each existing line when enabled' do
      allow(scraper).to receive(:cart_writes_enabled?).and_return(true)
      allow(api).to receive(:order_lines).and_return([{ product_key: '999', uom_type: 0, detail_id: 'd1' }])
      expect(api).to receive(:update_order_detail).with(hash_including(product_key: '999', quantity: 0))
      scraper.clear_cart
    end
  end

  describe '#verify_cart_matches!' do
    context 'Stage A (writes disabled)' do
      it 'skips reconciliation and returns true (nothing was written to mismatch)' do
        expect(api).not_to receive(:order_lines)
        expect(scraper.verify_cart_matches!(items)).to be(true)
      end
    end

    context 'Stage B (writes enabled)' do
      before { allow(scraper).to receive(:cart_writes_enabled?).and_return(true) }

      it 'passes when the draft matches exactly' do
        allow(api).to receive(:order_lines).and_return([
          { sku: '328740', quantity: 2 }, { sku: '543638', quantity: 1 }
        ])
        expect(scraper.verify_cart_matches!(items)).to be(true)
      end

      it 'fails CLOSED on an orphaned extra line in the draft' do
        allow(api).to receive(:order_lines).and_return([
          { sku: '328740', quantity: 2 }, { sku: '543638', quantity: 1 }, { sku: '000999', quantity: 5 }
        ])
        expect { scraper.verify_cart_matches!(items) }
          .to raise_error(Scrapers::BaseScraper::CartMismatchError, /extra_in_cart/)
      end

      it 'fails CLOSED on a quantity mismatch' do
        allow(api).to receive(:order_lines).and_return([
          { sku: '328740', quantity: 99 }, { sku: '543638', quantity: 1 }
        ])
        expect { scraper.verify_cart_matches!(items) }
          .to raise_error(Scrapers::BaseScraper::CartMismatchError, /quantity_mismatch/)
      end

      it 'fails CLOSED on a missing item' do
        allow(api).to receive(:order_lines).and_return([{ sku: '328740', quantity: 2 }])
        expect { scraper.verify_cart_matches!(items) }
          .to raise_error(Scrapers::BaseScraper::CartMismatchError, /missing_from_cart/)
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
