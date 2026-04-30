require 'rails_helper'

RSpec.describe Orders::OrderBuilderService, type: :service do
  let(:user) { create(:user, :with_organization) }
  let(:org) { user.current_organization }
  let(:location) { create(:location, user: user, organization: org) }
  let(:supplier) { create(:supplier) }

  let(:product_a) { create(:product, name: 'Tomato') }
  let(:product_b) { create(:product, name: 'Onion') }
  let(:product_c_unavailable) { create(:product, name: 'Saffron') }

  let!(:sp_a) { create(:supplier_product, product: product_a, supplier: supplier, current_price: 10.00, in_stock: true) }
  let!(:sp_b) { create(:supplier_product, product: product_b, supplier: supplier, current_price: 5.00, in_stock: true) }
  # product_c has no supplier_product for this supplier

  let(:order_list) do
    OrderList.create!(user: user, organization: org, name: 'Mise en place').tap do |list|
      list.order_list_items.create!(product: product_a, quantity: 2)
      list.order_list_items.create!(product: product_b, quantity: 3)
      list.order_list_items.create!(product: product_c_unavailable, quantity: 1)
    end
  end

  describe '#build' do
    it 'returns an unsaved order with order_items only for available products' do
      order = described_class.new(user: user, order_list: order_list, supplier: supplier, location: location).build

      expect(order).not_to be_persisted
      expect(order.order_items.size).to eq(2)
      expect(order.order_items.map { |i| i.supplier_product.product }).to contain_exactly(product_a, product_b)
    end

    it 'sets quantity, unit_price, line_total from supplier_product#current_price' do
      order = described_class.new(user: user, order_list: order_list, supplier: supplier).build
      tomato_item = order.order_items.find { |i| i.supplier_product == sp_a }

      expect(tomato_item.quantity).to eq(2)
      expect(tomato_item.unit_price).to eq(10.00)
      expect(tomato_item.line_total).to eq(20.00)
    end

    it 'sets subtotal and total_amount from line_totals' do
      order = described_class.new(user: user, order_list: order_list, supplier: supplier).build
      expect(order.subtotal).to eq(35.00) # 20 + 15
      expect(order.total_amount).to eq(35.00)
    end

    it 'wires location, organization, supplier, and order_list' do
      order = described_class.new(user: user, order_list: order_list, supplier: supplier, location: location).build
      expect(order.location).to eq(location)
      expect(order.organization_id).to eq(user.current_organization_id)
      expect(order.supplier).to eq(supplier)
      expect(order.order_list).to eq(order_list)
      expect(order.status).to eq('pending')
    end
  end

  describe '#build_and_save!' do
    it 'persists the order and marks the source order_list as used' do
      service = described_class.new(user: user, order_list: order_list, supplier: supplier, location: location)
      order = service.build_and_save!

      expect(order).to be_persisted
      expect(order.order_items).to all(be_persisted)
      expect(order_list.reload.last_used_at).to be_present
    end

    it 'raises when no items are available from the supplier' do
      bare_list = OrderList.create!(user: user, organization: org, name: 'Empty list')
      bare_list.order_list_items.create!(product: product_c_unavailable, quantity: 1)

      service = described_class.new(user: user, order_list: bare_list, supplier: supplier, location: location)
      expect { service.build_and_save! }.to raise_error(ArgumentError, /No items available/)
    end
  end

  describe '#preview' do
    it 'returns available_items, missing_items, totals, and minimum status' do
      preview = described_class.new(user: user, order_list: order_list, supplier: supplier, location: location).preview

      expect(preview[:item_count]).to eq(2)
      expect(preview[:missing_count]).to eq(1)
      expect(preview[:missing_items].first[:product_name]).to eq('Saffron')
      expect(preview[:subtotal]).to eq(35.00)
      expect(preview[:meets_minimum]).to be true
      expect(preview[:amount_to_minimum]).to eq(0)
    end

    it 'flags meets_minimum=false when subtotal falls short' do
      SupplierRequirement.create!(
        supplier: supplier, requirement_type: 'order_minimum',
        numeric_value: 100.00, error_message: 'minimum', active: true
      )

      preview = described_class.new(user: user, order_list: order_list, supplier: supplier).preview

      expect(preview[:meets_minimum]).to be false
      expect(preview[:amount_to_minimum]).to eq(65.00)
    end
  end
end
