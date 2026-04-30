require 'rails_helper'

RSpec.describe Orders::SplitOrderService, type: :service do
  let(:user) { create(:user, :with_organization) }
  let(:org) { user.current_organization }
  let(:location) { create(:location, user: user, organization: org, is_default: true) }
  let(:supplier_a) { create(:supplier, name: 'A') }
  let(:supplier_b) { create(:supplier, name: 'B') }
  let(:supplier_c) { create(:supplier, name: 'C') }

  let(:cheap_product) { create(:product, name: 'Cheap stuff') }
  let(:expensive_product) { create(:product, name: 'Premium stuff') }
  let(:exclusive_product) { create(:product, name: 'Only at C') }

  before do
    create(:supplier_credential, user: user, supplier: supplier_a, status: 'active')
    create(:supplier_credential, user: user, supplier: supplier_b, status: 'active')
    create(:supplier_credential, user: user, supplier: supplier_c, status: 'active')

    # cheap_product: A=8, B=10
    create(:supplier_product, product: cheap_product, supplier: supplier_a, current_price: 8.00, in_stock: true)
    create(:supplier_product, product: cheap_product, supplier: supplier_b, current_price: 10.00, in_stock: true)

    # expensive_product: A=20, B=15 (B is cheaper)
    create(:supplier_product, product: expensive_product, supplier: supplier_a, current_price: 20.00, in_stock: true)
    create(:supplier_product, product: expensive_product, supplier: supplier_b, current_price: 15.00, in_stock: true)

    # exclusive_product: only at C
    create(:supplier_product, product: exclusive_product, supplier: supplier_c, current_price: 5.00, in_stock: true)
  end

  let(:order_list) do
    OrderList.create!(user: user, organization: org, name: 'Split test').tap do |list|
      list.order_list_items.create!(product: cheap_product, quantity: 2)
      list.order_list_items.create!(product: expensive_product, quantity: 1)
      list.order_list_items.create!(product: exclusive_product, quantity: 1)
    end
  end

  describe '#preview' do
    it 'assigns each item to the cheapest supplier and reports per-supplier totals' do
      preview = described_class.new(order_list, location: location).preview

      a_assignment = preview[:assignments].find { |a| a[:supplier][:id] == supplier_a.id }
      b_assignment = preview[:assignments].find { |a| a[:supplier][:id] == supplier_b.id }
      c_assignment = preview[:assignments].find { |a| a[:supplier][:id] == supplier_c.id }

      expect(a_assignment[:items].first[:product_name]).to eq('Cheap stuff')
      expect(a_assignment[:subtotal]).to eq(16.00)

      expect(b_assignment[:items].first[:product_name]).to eq('Premium stuff')
      expect(b_assignment[:subtotal]).to eq(15.00)

      expect(c_assignment[:items].first[:product_name]).to eq('Only at C')
      expect(c_assignment[:subtotal]).to eq(5.00)
    end

    it 'flags unassigned items as warnings' do
      orphan = create(:product, name: 'Orphan')
      order_list.order_list_items.create!(product: orphan, quantity: 1)

      preview = described_class.new(order_list, location: location).preview
      orphan_warning = preview[:warnings].find { |w| w[:type] == 'unassigned_items' }
      expect(orphan_warning).to be_present
      expect(orphan_warning[:items].first[:product_name]).to eq('Orphan')
    end

    it 'flags minimum_not_met warnings when a supplier-shard falls below minimum' do
      SupplierRequirement.create!(
        supplier: supplier_a, requirement_type: 'order_minimum',
        numeric_value: 100.00, error_message: 'min', active: true
      )

      preview = described_class.new(order_list, location: location).preview
      min_warning = preview[:warnings].find { |w| w[:type] == 'minimum_not_met' }
      expect(min_warning).to be_present
      expect(min_warning[:shortfall]).to eq(84.00)
    end
  end

  describe '#create_orders!' do
    it 'creates one order per assigned supplier' do
      orders = described_class.new(order_list, location: location).create_orders!(delivery_date: 3.days.from_now.to_date)

      expect(orders.size).to eq(3)
      expect(orders.map(&:supplier)).to contain_exactly(supplier_a, supplier_b, supplier_c)
      expect(orders).to all(be_persisted)
      expect(orders.map(&:status).uniq).to eq(['pending'])
    end

    it 'raises OrderMinimumError if any shard misses its minimum' do
      SupplierRequirement.create!(
        supplier: supplier_a, requirement_type: 'order_minimum',
        numeric_value: 100.00, error_message: 'min', active: true
      )

      service = described_class.new(order_list, location: location)
      expect { service.create_orders! }.to raise_error(Orders::SplitOrderService::OrderMinimumError)
    end

    it 'is transactional — failure rolls back partial creates' do
      SupplierRequirement.create!(
        supplier: supplier_a, requirement_type: 'order_minimum',
        numeric_value: 100.00, error_message: 'min', active: true
      )

      expect {
        begin
          described_class.new(order_list, location: location).create_orders!
        rescue Orders::SplitOrderService::OrderMinimumError
          # swallowed for rollback verification
        end
      }.not_to change(Order, :count)
    end
  end

  describe '#submit_all!' do
    let(:orders) { described_class.new(order_list, location: location).create_orders! }

    it 'enqueues PlaceOrderJob for each order with staggered waits' do
      expect {
        described_class.new(order_list, location: location).submit_all!(orders)
      }.to have_enqueued_job(PlaceOrderJob).exactly(orders.size).times
    end

    it 'updates each order to processing status' do
      described_class.new(order_list, location: location).submit_all!(orders)
      expect(orders.map { |o| o.reload.status }.uniq).to eq(['processing'])
    end
  end
end
