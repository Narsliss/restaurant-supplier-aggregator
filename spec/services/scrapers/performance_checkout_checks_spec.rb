require 'rails_helper'

# Plan Phase 4 (Oct 19 2026): Performance names a line that didn't land,
# shows its own rejection reason, and never calls an unanswered submit
# placed or failed without reading the order back.
RSpec.describe Scrapers::PerformanceScraper, 'checkout checks' do
  let(:supplier) { create(:supplier) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:scraper) { described_class.new(credential) }
  let(:api) { instance_double(Scrapers::PerformanceApi) }
  let(:oeh) { 'oeh-1' }
  let(:items) { [{ sku: '328740', name: 'TOMATO', quantity: 2 }, { sku: '543638', name: 'OIL', quantity: 1 }] }

  before do
    allow(scraper).to receive(:api_client).and_return(api)
    allow(scraper).to receive(:cart_writes_enabled?).and_return(true)
    allow(scraper).to receive(:sleep)
    allow(api).to receive(:ensure_session!)
    allow(api).to receive(:account_context).and_return(order_entry_header_id: oeh, customer_id: 'cust')
  end

  describe 'checking each line as it is added' do
    # A draft that holds what update_order_detail sets, except the SKUs PFG
    # answers IsSuccess for and silently drops.
    let(:cart) { {} }
    let(:dropped) { [] }

    before do
      allow(api).to receive(:product_by_sku) { |sku| { 'ProductKey' => sku } }
      allow(api).to receive(:fetch_prices) { |skus| skus.to_h { |s| [s, 10.0] } }
      allow(api).to receive(:update_order_detail) do |product:, quantity:, **|
        cart[product['ProductKey']] = quantity unless dropped.include?(product['ProductKey'])
        { 'IsSuccess' => true }
      end
      allow(api).to receive(:get_order) { { 'TotalLines' => cart.size, 'TotalQuantity' => cart.values.sum } }
    end

    it 'adds every line PFG holds' do
      result = scraper.add_to_cart(items)

      expect(result[:added].map { |i| i[:sku] }).to eq(%w[328740 543638])
      expect(result[:failed]).to be_empty
    end

    it "names a line PFG said yes to but didn't hold, without blaming the next one" do
      dropped << '328740'

      result = scraper.add_to_cart(items)

      expect(result[:failed]).to eq([items.first.merge(reason: "Performance didn't add it to the cart")])
      expect(result[:added].map { |i| i[:sku] }).to eq(['543638'])
    end

    it 'judges each add against what the draft already held' do
      cart['999999'] = 4 # a line already there (verify_cart_matches! still refuses it before submit)

      expect(scraper.add_to_cart(items)[:failed]).to be_empty
    end

    it 'leaves the totals check to verify_cart_matches! when the draft cannot be read' do
      dropped << '328740'
      allow(api).to receive(:get_order).and_raise(Scrapers::PerformanceApi::ApiError, 'HTTP 502')

      expect(scraper.add_to_cart(items)[:failed]).to be_empty
    end
  end

  describe 'the submit' do
    let(:order) { { 'TotalLines' => 2, 'TotalQuantity' => 3, 'TotalOrderPrice' => 120.0, 'DeliveryDate' => '2026-10-21T00:00:00' } }

    before do
      scraper.instance_variable_set(:@verified_totals, { lines: 2, qty: 3 })
    end

    it "shows Performance's own reason when it rejects the order" do
      allow(api).to receive(:get_order).and_return(order)
      allow(api).to receive(:submit_order).and_return(
        'IsSuccess' => true, 'ErrorMessages' => [],
        'ResultObject' => { 'AcceptOrder' => false, 'RejectedMessage' => 'Order is past the cutoff for Wed 10/21' }
      )

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, 'Performance rejected the order: Order is past the cutoff for Wed 10/21')
    end

    it 'calls a timed-out submit placed when the order reads back numbered with the lines we sent' do
      allow(api).to receive(:submit_order).and_raise(Net::ReadTimeout)
      allow(api).to receive(:get_order).and_return(order, order.merge('OrderNumber' => '1296580'))

      result = scraper.checkout(dry_run: false)

      expect(result).to include(confirmation_number: '1296580', total: 120.0, dry_run: false)
    end

    it 'calls a timed-out submit unconfirmed while the order has no number' do
      allow(api).to receive(:submit_order).and_raise(Net::ReadTimeout)
      allow(api).to receive(:get_order).and_return(order)

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError, /no clear answer.*before ordering again/)
      expect(api).to have_received(:get_order).exactly(4).times
    end

    it 'reads the order back after an empty reply or a server error' do
      allow(api).to receive(:get_order).and_return(order)

      allow(api).to receive(:submit_order).and_return(nil)
      expect { scraper.checkout(dry_run: false) }.to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError)

      allow(api).to receive(:submit_order).and_raise(Scrapers::PerformanceApi::ApiError, 'HTTP 502 for OrderEntryHeader/SubmitOrderEntryHeader')
      expect { scraper.checkout(dry_run: false) }.to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError)
    end

    it 'flags a numbered order that holds other totals than we sent' do
      allow(api).to receive(:submit_order).and_raise(Net::ReadTimeout)
      allow(api).to receive(:get_order).and_return(order, order.merge('OrderNumber' => '1296580', 'TotalLines' => 1, 'TotalQuantity' => 2))

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError, /#1296580.*1 item\(s\) and 2 case\(s\), not the 2 and 3 we sent/)
    end

    it 'fails plainly when the login is turned away at submit' do
      allow(api).to receive(:get_order).and_return(order)
      allow(api).to receive(:submit_order).and_raise(Scrapers::PerformanceApi::AuthError, 'Unauthenticated (HTTP 401)')

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::NotPlacedError, /turned the login away.*nothing was placed.*Reconnect Performance/)
      expect(scraper.submit_sent?).to be(true)
    end

    it 'marks the submit as sent only when it goes out' do
      allow(api).to receive(:get_order).and_return(order)
      expect { scraper.checkout(dry_run: true) }.not_to change(scraper, :submit_sent?)

      allow(api).to receive(:submit_order).and_return('IsSuccess' => true, 'ResultObject' => { 'AcceptOrder' => true, 'OrderNumber' => '1' })
      scraper.checkout(dry_run: false)
      expect(scraper.submit_sent?).to be(true)
    end
  end
end
