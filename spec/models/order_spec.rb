require 'rails_helper'

RSpec.describe Order, type: :model do
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
