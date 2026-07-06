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
end
