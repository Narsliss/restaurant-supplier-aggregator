# frozen_string_literal: true

require 'rails_helper'

# PRD2 P4: canonical image resolution for order line items (review/placed-order
# pages). This is decorative and runs on the checkout path, so the contract that
# matters most is: it must NEVER raise and NEVER cross organization boundaries.
RSpec.describe Order, 'canonical image resolution' do
  describe '#canonical_image_sources_by_supplier_product' do
    it 'returns an empty map when the order has no supplier products' do
      order = described_class.new(organization_id: 1)
      expect(order.canonical_image_sources_by_supplier_product).to eq({})
    end

    it 'returns an empty map when the order has no organization (cannot scope safely)' do
      order = described_class.new(organization_id: nil)
      order.order_items.build(supplier_product_id: 42, quantity: 1, unit_price: 1)
      expect(order.canonical_image_sources_by_supplier_product).to eq({})
    end

    it 'never raises on the checkout path: a query failure degrades to no image' do
      order = described_class.new(organization_id: 1)
      order.order_items.build(supplier_product_id: 42, quantity: 1, unit_price: 1)
      allow(ProductMatchItem).to receive(:joins).and_raise(ActiveRecord::StatementInvalid, 'boom')

      expect { order.canonical_image_sources_by_supplier_product }.not_to raise_error
      expect(order.canonical_image_sources_by_supplier_product).to eq({})
    end

    it 'memoizes so the resolving query runs once per order' do
      order = described_class.new(organization_id: 1)
      first = order.canonical_image_sources_by_supplier_product
      expect(order.canonical_image_sources_by_supplier_product).to equal(first)
    end
  end

  describe '#canonical_image_source_for' do
    it 'returns nil for an item whose supplier product is not in the map' do
      order = described_class.new(organization_id: 1)
      item = order.order_items.build(supplier_product_id: 999, quantity: 1, unit_price: 1)
      expect(order.canonical_image_source_for(item)).to be_nil
    end
  end
end
