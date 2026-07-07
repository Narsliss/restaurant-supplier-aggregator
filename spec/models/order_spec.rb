require 'rails_helper'

RSpec.describe Order, type: :model do
  describe 'supplier exceptions' do
    let(:usf) { Supplier.find_by(code: 'usfoods') || create(:supplier, code: 'usfoods') }

    it '#has_supplier_exceptions? reflects whether any are recorded' do
      order = build(:order, supplier_exceptions: [])
      expect(order.has_supplier_exceptions?).to be false
      order.supplier_exceptions = [{ 'type' => 'out_of_stock', 'sku' => 'X' }]
      expect(order.has_supplier_exceptions?).to be true
    end

    it '#supplier_order_url deep-links to US Foods (only)' do
      expect(build(:order, supplier: usf).supplier_order_url).to include('order.usfoods.com')
      non_usf = Supplier.find_by(code: 'sysco') || create(:supplier, code: 'sysco')
      expect(build(:order, supplier: non_usf).supplier_order_url).to be_nil
    end

    it '#awaiting_exception_check? is true for a fresh, unchecked USF submit' do
      order = build(:order, supplier: usf, status: 'submitted', submitted_at: 1.minute.ago, exceptions_checked_at: nil)
      expect(order.awaiting_exception_check?).to be true
    end

    it '#awaiting_exception_check? is false once the check has run' do
      order = build(:order, supplier: usf, status: 'submitted', submitted_at: 1.minute.ago, exceptions_checked_at: Time.current)
      expect(order.awaiting_exception_check?).to be false
    end

    it '#awaiting_exception_check? is false for an old submission' do
      order = build(:order, supplier: usf, status: 'submitted', submitted_at: 1.hour.ago, exceptions_checked_at: nil)
      expect(order.awaiting_exception_check?).to be false
    end
  end

  describe 'state predicates' do
    it 'is completed? for submitted, confirmed, and dry_run_complete' do
      expect(build(:order, :submitted).completed?).to be true
      expect(build(:order, :confirmed).completed?).to be true
      expect(build(:order, :dry_run_complete).completed?).to be true
    end

    it 'is not completed? for non-terminal statuses' do
      expect(build(:order, status: 'pending').completed?).to be false
      expect(build(:order, status: 'processing').completed?).to be false
      expect(build(:order, :failed).completed?).to be false
      expect(build(:order, :draft).completed?).to be false
    end
  end

  describe '#calculated_subtotal' do
    it 'sums line_total across all items' do
      order = create(:order)
      create(:order_item, order: order, quantity: 2, unit_price: 10)
      create(:order_item, order: order, quantity: 1, unit_price: 5.50)

      expect(order.calculated_subtotal).to eq(25.50)
    end
  end

  describe '#recalculate_totals!' do
    it 'updates subtotal and total_amount from line items' do
      order = create(:order, tax: 2.00)
      create(:order_item, order: order, quantity: 3, unit_price: 10)

      order.recalculate_totals!

      expect(order.subtotal).to eq(30)
      expect(order.total_amount).to eq(32)
    end
  end
end
