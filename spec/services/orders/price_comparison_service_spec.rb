require 'rails_helper'

RSpec.describe Orders::PriceComparisonService, type: :service do
  let(:user) { create(:user, :with_organization) }
  let(:org) { user.current_organization }
  let(:supplier_a) { create(:supplier, name: 'A Supplier', code: 'a-sup') }
  let(:supplier_b) { create(:supplier, name: 'B Supplier', code: 'b-sup') }
  let(:product) { create(:product, name: 'Pasta', category: 'Dry Goods') }

  let(:order_list) do
    OrderList.create!(user: user, organization: org, name: 'Test list').tap do |list|
      list.order_list_items.create!(product: product, quantity: 2)
    end
  end

  before do
    create(:supplier_credential, user: user, supplier: supplier_a, status: 'active')
    create(:supplier_credential, user: user, supplier: supplier_b, status: 'active')
  end

  context 'when only one supplier has the product' do
    let!(:sp_a) { create(:supplier_product, supplier: supplier_a, product: product, current_price: 10.00, in_stock: true, pack_size: '5 LB') }

    it 'returns supplier_prices for both suppliers, marking the missing one unavailable' do
      result = described_class.new(order_list).compare

      item = result[:items].first
      expect(item[:suppliers].size).to eq(2)

      a_entry = item[:suppliers].find { |s| s[:supplier][:id] == supplier_a.id }
      b_entry = item[:suppliers].find { |s| s[:supplier][:id] == supplier_b.id }

      expect(a_entry[:unit_price]).to eq(10.00)
      expect(a_entry[:line_total]).to eq(20.00)
      expect(b_entry[:unavailable]).to be true
    end
  end

  context 'when two suppliers have the same product' do
    let!(:sp_a) { create(:supplier_product, supplier: supplier_a, product: product, current_price: 10.00, in_stock: true, pack_size: '5 LB') }
    let!(:sp_b) { create(:supplier_product, supplier: supplier_b, product: product, current_price: 12.00, in_stock: true, pack_size: '5 LB') }

    it 'identifies the best price as supplier A' do
      result = described_class.new(order_list).compare

      best = result[:items].first[:best_price]
      expect(best[:supplier_id]).to eq(supplier_a.id)
      expect(best[:unit_price]).to eq(10.00)
    end

    it 'identifies the worst price as supplier B' do
      worst = described_class.new(order_list).compare[:items].first[:worst_price]
      expect(worst[:supplier_id]).to eq(supplier_b.id)
    end

    it 'computes price_spread' do
      spread = described_class.new(order_list).compare[:items].first[:price_spread]
      expect(spread).to be > 0
    end

    it 'computes per-supplier totals' do
      totals = described_class.new(order_list).compare[:totals_by_supplier]

      expect(totals[supplier_a.id][:total]).to eq(20.00)
      expect(totals[supplier_b.id][:total]).to eq(24.00)
      expect(totals[supplier_a.id][:available_items]).to eq(1)
      expect(totals[supplier_b.id][:missing_items]).to eq(0)
    end

    it 'recommends the cheapest supplier when both have all items' do
      rec = described_class.new(order_list).compare[:recommendations]
      expect(rec[:best_single_supplier][:supplier_id]).to eq(supplier_a.id)
      expect(rec[:recommendation]).to include(supplier_a.name)
    end
  end

  context 'when no supplier carries an item' do
    it 'returns a recommendation flagging missing coverage' do
      result = described_class.new(order_list).compare
      expect(result[:recommendations][:best_single_supplier]).to be_nil
      expect(result[:recommendations][:recommendation]).to match(/No single supplier|No suppliers meet/)
    end
  end

  context 'when an item is out of stock at the cheaper supplier' do
    let!(:sp_a) { create(:supplier_product, supplier: supplier_a, product: product, current_price: 10.00, in_stock: false, pack_size: '5 LB') }
    let!(:sp_b) { create(:supplier_product, supplier: supplier_b, product: product, current_price: 12.00, in_stock: true, pack_size: '5 LB') }

    it 'best_price ignores out-of-stock listings' do
      best = described_class.new(order_list).compare[:items].first[:best_price]
      expect(best[:supplier_id]).to eq(supplier_b.id)
    end
  end

  context 'with order minimums' do
    let!(:sp_a) { create(:supplier_product, supplier: supplier_a, product: product, current_price: 10.00, in_stock: true, pack_size: '5 LB') }

    before do
      SupplierRequirement.create!(
        supplier: supplier_a, requirement_type: 'order_minimum',
        numeric_value: 100.00, error_message: 'Below minimum', active: true
      )
    end

    it 'reports meets_minimum=false when total falls short' do
      totals = described_class.new(order_list).compare[:totals_by_supplier]
      expect(totals[supplier_a.id][:meets_minimum]).to be false
      expect(totals[supplier_a.id][:amount_to_minimum]).to eq(80.00)
    end
  end

  context 'active_suppliers is sourced from active credentials only' do
    let!(:supplier_c) { create(:supplier, code: 'c-sup') }
    # No credential for supplier_c

    it 'omits suppliers without an active credential' do
      result = described_class.new(order_list).compare
      ids = result[:items].first[:suppliers].map { |s| s[:supplier][:id] }
      expect(ids).to contain_exactly(supplier_a.id, supplier_b.id)
    end
  end
end
