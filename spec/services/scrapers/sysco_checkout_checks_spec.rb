require 'rails_helper'

# Plan Phase 4 (Oct 19 2026): Sysco checks every line before submit and only
# calls an order placed when Sysco's own order list says so.
RSpec.describe Scrapers::SyscoScraper do
  subject(:scraper) { described_class.allocate }

  before do
    allow(scraper).to receive(:logger).and_return(Logger.new(nil))
    allow(scraper).to receive(:ensure_api_session!)
    allow(scraper).to receive(:load_api_tokens).and_return(site_id: '019', seller_id: 'USBL', shop_account_id: 'usbl-019-1')
    allow(scraper).to receive(:graphql_delete_order)
  end

  let(:sugar) { { sku: '4279592', name: 'Sugar', quantity: 2, expected_price: 40.59 } }
  let(:flour) { { sku: '6081093', name: 'Flour', quantity: 1, expected_price: 21.10 } }

  def echo_line(sku, qty, sold_as: 'CASE')
    { 'productId' => sku, 'qty' => qty, 'soldAs' => sold_as, 'sellerId' => 'USBL', 'siteId' => '019' }
  end

  def stub_update(lines)
    allow(scraper).to receive(:graphql_create_order).and_return('id' => 'o1', 'sequenceId' => 1)
    allow(scraper).to receive(:graphql_update_order).and_return('sequenceId' => 2, 'lineItems' => lines)
    allow(scraper).to receive(:price_with_sellers) do |skus, **|
      { prices: {}, sellers: skus.to_h { |s| [s.to_s, 'USBL'] }, unlisted: [], third_party: [] }
    end
  end

  describe 'checking the draft before submit' do
    it 'passes when Sysco holds every line as ordered, by the case' do
      stub_update([echo_line('4279592', 2), echo_line('6081093', 1)])
      scraper.add_to_cart([sugar, flour])

      expect(scraper.verify_cart_matches!([sugar, flour])).to be(true)
      expect(scraper).not_to have_received(:graphql_delete_order)
    end

    it 'stops the order and deletes the draft when Sysco holds another quantity' do
      stub_update([echo_line('4279592', 1), echo_line('6081093', 1)])
      scraper.add_to_cart([sugar, flour])

      expect { scraper.verify_cart_matches!([sugar, flour]) }.to raise_error(Scrapers::BaseScraper::CartMismatchError) { |e|
        expect(e.discrepancies).to eq([{ type: 'quantity_mismatch', sku: '4279592', cart_qty: 1, expected_qty: 2 }])
      }
      expect(scraper).to have_received(:graphql_delete_order).with('o1')
    end

    it 'stops the order when Sysco holds a line by the piece' do
      stub_update([echo_line('4279592', 2, sold_as: 'EACH')])
      scraper.add_to_cart([sugar])

      expect { scraper.verify_cart_matches!([sugar]) }.to raise_error(Scrapers::BaseScraper::CartMismatchError) { |e|
        expect(e.discrepancies).to eq([{ type: 'uom_mismatch', sku: '4279592', cart_uom: :piece, expected_uom: :case }])
      }
    end

    it 'stops the order when Sysco does not say how a line is sold' do
      stub_update([echo_line('4279592', 2, sold_as: nil)])
      scraper.add_to_cart([sugar])

      expect { scraper.verify_cart_matches!([sugar]) }
        .to raise_error(Scrapers::BaseScraper::CartMismatchError) { |e| expect(e.discrepancies.first[:type]).to eq('uom_mismatch') }
    end

    it 'stops the order when the draft holds a line the order does not' do
      stub_update([echo_line('4279592', 2), echo_line('9999999', 3)])
      scraper.add_to_cart([sugar])

      expect { scraper.verify_cart_matches!([sugar]) }.to raise_error(Scrapers::BaseScraper::CartMismatchError) { |e|
        expect(e.discrepancies).to eq([{ type: 'extra_in_cart', sku: '9999999', cart_qty: 3 }])
      }
    end

    it "submits the chef's quantity, never Sysco's echo" do
      stub_update([echo_line('4279592', 1)])
      scraper.add_to_cart([sugar])

      expect(scraper.instance_variable_get(:@last_sysco_line_items))
        .to eq([{ qty: 2, soldAs: 'cs', productId: '4279592', siteId: '019', sellerId: 'USBL' }])
    end
  end

  describe 'a refused update' do
    before do
      stub_update([])
      allow(scraper).to receive(:graphql_update_order)
        .and_raise(Scrapers::BaseScraper::ScrapingError, 'updateOrderV2 failed: Product 6081093 is not available for seller USBL')
    end

    it 'names the item Sysco refused, in its words, and deletes the draft' do
      expect { scraper.add_to_cart([sugar, flour]) }.to raise_error(Scrapers::BaseScraper::ItemUnavailableError) { |e|
        expect(e.items).to eq([{ sku: '6081093', name: 'Flour', error: 'Sysco: Product 6081093 is not available for seller USBL' }])
      }
      expect(scraper).to have_received(:graphql_delete_order).with('o1')
    end

    it 'keeps a refusal that names no item a plain failure' do
      allow(scraper).to receive(:graphql_update_order)
        .and_raise(Scrapers::BaseScraper::ScrapingError, 'updateOrderV2 failed: order.lineItems[0].price is required')

      expect { scraper.add_to_cart([sugar, flour]) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, /price is required/) { |e|
          expect(e).not_to be_a(Scrapers::BaseScraper::ItemUnavailableError)
        }
    end
  end

  describe 'confirming a live submit' do
    let(:draft) { { 'id' => 'o1', 'name' => 'Oct 19 2026 09:00 AM', 'status' => 'OPEN', 'totalPrice' => 102.28, 'totalLineItems' => 2, 'deliveryDate' => '10/21/2026' } }
    let(:submitted) { draft.merge('status' => 'SUBMITTED', 'totalPrice' => 103.50) }

    before do
      scraper.instance_variable_set(:@last_sysco_order_id, 'o1')
      scraper.instance_variable_set(:@last_sysco_sequence_id, 2)
      scraper.instance_variable_set(:@last_sysco_line_items, [
                                      { qty: 2, soldAs: 'cs', productId: '4279592', siteId: '019', sellerId: 'USBL' },
                                      { qty: 1, soldAs: 'cs', productId: '6081093', siteId: '019', sellerId: 'USBL' }
                                    ])
      allow(scraper).to receive(:graphql_available_delivery_days).and_return([])
      allow(scraper).to receive(:sleep)
      allow(scraper).to receive(:graphql_submit_order).and_return('__typename' => 'OrderSubmitResponseV2')
    end

    # First lookup is the pre-submit read of the draft; the rest follow submit.
    def headers_after_submit(*after)
      allow(scraper).to receive(:graphql_get_open_orders).and_return([draft], *after)
    end

    it "calls it placed once Sysco lists the order as submitted with every line" do
      headers_after_submit([submitted])

      result = scraper.checkout(dry_run: false)

      expect(result).to include(confirmation_number: 'Oct 19 2026 09:00 AM', total: 103.50)
    end

    it 'waits for Sysco to list the order as submitted' do
      headers_after_submit([draft], [submitted])

      expect(scraper.checkout(dry_run: false)[:confirmation_number]).to eq('Oct 19 2026 09:00 AM')
      expect(scraper).to have_received(:sleep).once
    end

    it 'does not call it placed while Sysco still lists a cart' do
      headers_after_submit([draft], [draft], [draft])

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError, /still lists it as a cart.*before ordering again/)
      expect(scraper).to have_received(:graphql_get_open_orders).exactly(4).times
    end

    it 'does not call it placed when Sysco has no such order' do
      headers_after_submit([], [], [])

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError, /couldn't find it in Sysco's orders/)
    end

    it 'does not call it placed when the lookup itself fails' do
      calls = 0
      allow(scraper).to receive(:graphql_get_open_orders) do
        calls += 1
        raise Net::ReadTimeout if calls > 1

        [draft]
      end

      expect { scraper.checkout(dry_run: false) }.to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError)
    end

    it 'flags an order Sysco took with fewer lines than we sent' do
      headers_after_submit([submitted.merge('totalLineItems' => 1)])

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError, /shows 1 of the 2 items we sent/)
    end

    it 'flags a cancelled order' do
      headers_after_submit(*Array.new(3) { [submitted.merge('status' => 'CANCELLED')] })

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError, /lists it as cancelled/)
    end

    it "finds out from Sysco's orders when the submit times out" do
      allow(scraper).to receive(:graphql_submit_order).and_raise(Net::ReadTimeout)
      headers_after_submit([submitted])

      expect(scraper.checkout(dry_run: false)[:confirmation_number]).to eq('Oct 19 2026 09:00 AM')
    end

    it 'calls a timed-out submit unconfirmed when Sysco still lists a cart' do
      allow(scraper).to receive(:graphql_submit_order)
        .and_raise(Scrapers::BaseScraper::ScrapingError, 'Sysco API error 504 on SubmitOrder: timeout')
      headers_after_submit([draft], [draft], [draft])

      expect { scraper.checkout(dry_run: false) }.to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError)
    end

    it 'fails plainly when Sysco refuses the submit and still lists a cart' do
      allow(scraper).to receive(:graphql_submit_order)
        .and_raise(described_class::NotSubmittedError, 'submitOrderV2 failed: The given delivery date is invalid (code=1002)')
      headers_after_submit([draft])

      expect { scraper.checkout(dry_run: false) }
        .to raise_error(described_class::NotSubmittedError, /delivery date is invalid/)
      expect(scraper).to have_received(:graphql_get_open_orders).twice
      expect(scraper).not_to have_received(:sleep)
    end

    it 'fails plainly when Sysco refuses the submit and the lookup fails' do
      allow(scraper).to receive(:graphql_submit_order).and_raise(described_class::NotSubmittedError, 'submitOrderV2 failed: nope')
      calls = 0
      allow(scraper).to receive(:graphql_get_open_orders) do
        calls += 1
        raise Net::ReadTimeout if calls > 1

        [draft]
      end

      expect { scraper.checkout(dry_run: false) }.to raise_error(described_class::NotSubmittedError, /nope/)
    end

    # A refusal Sysco's own list contradicts must not invite a second order.
    it 'calls a refused submit placed when Sysco lists the order as submitted' do
      allow(scraper).to receive(:graphql_submit_order).and_raise(described_class::NotSubmittedError, 'submitOrderV2 failed: odd')
      headers_after_submit([submitted])

      expect(scraper.checkout(dry_run: false)[:confirmation_number]).to eq('Oct 19 2026 09:00 AM')
    end

    it 'raises NotSubmittedError when Sysco answers the submit with errors' do
      allow(scraper).to receive(:graphql_submit_order).and_call_original
      allow(scraper).to receive(:graphql_request).and_return(
        'data' => { 'submitOrderV2' => nil }, 'errors' => [{ 'message' => 'The given delivery date is invalid' }]
      )

      expect { scraper.send(:graphql_submit_order, order_id: 'o1', sequence_id: 2) }
        .to raise_error(described_class::NotSubmittedError, /delivery date is invalid/)
    end
  end
end
