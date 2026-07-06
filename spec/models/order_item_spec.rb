require 'rails_helper'

RSpec.describe OrderItem, type: :model do
  describe 'callbacks' do
    describe 'calculate_line_total' do
      it 'sets line_total to quantity * unit_price on create' do
        item = create(:order_item, quantity: 4, unit_price: 7.25)
        expect(item.line_total).to eq(29.00)
      end

      it 'recomputes line_total when quantity or unit_price changes' do
        item = create(:order_item, quantity: 2, unit_price: 10)
        item.update!(quantity: 5)
        expect(item.line_total).to eq(50.00)
      end
    end

    describe 'snapshot_product_info' do
      it 'snapshots supplier_name and supplier_sku from supplier_product on create' do
        sp = create(:supplier_product, supplier_name: 'Snapped Item', supplier_sku: 'SNAP-1')
        item = create(:order_item, supplier_product: sp)

        expect(item.product_name).to eq('Snapped Item')
        expect(item.product_sku).to eq('SNAP-1')
      end

      it 'preserves the snapshot if the supplier_product is later deleted' do
        sp = create(:supplier_product, supplier_name: 'Snapped Item', supplier_sku: 'SNAP-1')
        item = create(:order_item, supplier_product: sp)
        sp.destroy!

        expect(item.reload.supplier_name).to eq('Snapped Item')
        expect(item.supplier_sku).to eq('SNAP-1')
      end
    end
  end

  describe 'status transitions' do
    let(:item) { create(:order_item, status: 'pending') }

    it '#mark_added! flips status to added' do
      item.mark_added!
      expect(item.reload).to be_added
    end

    it '#mark_failed! sets failed and stores notes' do
      item.mark_failed!('out of stock')
      expect(item.reload).to be_failed
      expect(item.notes).to eq('out of stock')
    end

    it '#mark_skipped! sets skipped and stores reason in notes' do
      item.mark_skipped!('user removed')
      expect(item.reload).to be_skipped
      expect(item.notes).to eq('user removed')
    end
  end

  describe '#price_changed? and #update_to_current_price!' do
    let(:supplier_product) { create(:supplier_product, current_price: 12.00) }
    let(:item) { create(:order_item, supplier_product: supplier_product, quantity: 3, unit_price: 10.00) }

    it 'detects when supplier_product#current_price differs from unit_price' do
      expect(item.price_changed?).to be true
      expect(item.current_price_difference).to eq(2.00)
    end

    it 'updates unit_price and line_total to current_price and recalculates the order' do
      item.update_to_current_price!

      expect(item.reload.unit_price).to eq(12.00)
      expect(item.line_total).to eq(36.00)
      expect(item.order.reload.subtotal).to eq(36.00)
    end
  end

  # Regression: a piece (PC) line must be compared against the piece price, not
  # the case price. Comparing $85.48 (piece) to $466.32 (case) reported a bogus
  # +445% "price changed" and blocked a real order.
  describe '#price_changed? with piece (PC) pricing' do
    let(:supplier_product) { create(:supplier_product, current_price: 466.32, piece_price: 85.48) }

    it 'compares a PC line against the piece price, not the case price' do
      item = create(:order_item, supplier_product: supplier_product, uom: 'PC', quantity: 1, unit_price: 85.48)

      expect(item.current_supplier_unit_price).to eq(85.48)
      expect(item.price_changed?).to be false
      expect(item.current_price_difference).to eq(0)
    end

    it 'still detects a genuine change on a PC line (vs the piece price)' do
      item = create(:order_item, supplier_product: supplier_product, uom: 'PC', quantity: 1, unit_price: 80.00)

      expect(item.price_changed?).to be true
      expect(item.current_price_difference).to eq(5.48)
    end

    it 'compares a case line against the case price' do
      item = create(:order_item, supplier_product: supplier_product, uom: 'CS', quantity: 1, unit_price: 466.32)

      expect(item.current_supplier_unit_price).to eq(466.32)
      expect(item.price_changed?).to be false
    end

    it 'falls back to the case price for a PC line when no piece price is stored' do
      sp = create(:supplier_product, current_price: 466.32, piece_price: nil)
      item = create(:order_item, supplier_product: sp, uom: 'PC', quantity: 1, unit_price: 466.32)

      expect(item.current_supplier_unit_price).to eq(466.32)
      expect(item.price_changed?).to be false
    end

    it 'updates a PC line to the piece price' do
      item = create(:order_item, supplier_product: supplier_product, uom: 'PC', quantity: 2, unit_price: 80.00)
      item.update_to_current_price!

      expect(item.reload.unit_price).to eq(85.48)
      expect(item.line_total).to eq(170.96)
    end
  end

  describe 'verified price helpers' do
    let(:item) { create(:order_item, quantity: 2, unit_price: 10.00, verified_price: 11.00) }

    it '#verified_price_difference returns the absolute change' do
      expect(item.verified_price_difference).to eq(1.00)
    end

    it '#verified_price_changed? is true when verified_price differs from unit_price' do
      expect(item.verified_price_changed?).to be true
    end

    it '#verified_price_change_percentage rounds to one decimal' do
      expect(item.verified_price_change_percentage).to eq(10.0)
    end

    it 'returns 0 when verified_price is nil' do
      item.update!(verified_price: nil)
      expect(item.verified_price_difference).to eq(0)
      expect(item.verified_price_changed?).to be false
    end
  end
end
