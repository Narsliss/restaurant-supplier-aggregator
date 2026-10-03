require 'rails_helper'

RSpec.describe Orders::OrderValidationService, type: :service do
  let(:user) { create(:user, :with_organization) }
  let(:supplier) { create(:supplier) }
  let(:order) { create(:order, user: user, supplier: supplier, organization: user.current_organization) }
  let(:service) { described_class.new(order) }

  def price_change_warning
    service.send(:validate_price_changes)
    service.warnings.find { |w| w[:type] == 'price_changed' }
  end

  # Carmin, Oct 3 2026: the supplier decides availability at add-to-cart. We
  # used to delete lines our cache marked out of stock and place the rest.
  describe 'cached out-of-stock items' do
    let(:in_stock) { create(:supplier_product, supplier: supplier, in_stock: true) }
    let(:cached_oos) { create(:supplier_product, supplier: supplier, in_stock: false) }
    let!(:credential) { create(:supplier_credential, user: user, supplier: supplier, status: 'active') }

    it 'never deletes order lines or warns because of our cached stock flag' do
      create(:order_item, order: order, supplier_product: in_stock, quantity: 1, unit_price: 10)
      create(:order_item, order: order, supplier_product: cached_oos, quantity: 1, unit_price: 10)

      service.validate!

      expect(order.order_items.reload.count).to eq(2)
      expect(service.warnings.map { |w| w[:type] }).not_to include('items_removed')
    end

    it 'does not block an order whose every item is cached out of stock' do
      create(:order_item, order: order, supplier_product: cached_oos, quantity: 1, unit_price: 10)

      expect { service.validate! }.not_to raise_error
      expect(order.order_items.reload.count).to eq(1)
    end
  end

  describe '#validate_price_changes with piece (PC) pricing' do
    let(:supplier_product) { create(:supplier_product, supplier: supplier, current_price: 466.32, piece_price: 85.48) }

    # Regression: order #127 raised a false "1 item changed price ... +445%"
    # warning because a PC line ($85.48) was compared to the case price ($466.32).
    it 'does NOT warn when a PC line matches the current piece price' do
      create(:order_item, order: order, supplier_product: supplier_product, uom: 'PC', quantity: 1, unit_price: 85.48)

      expect(price_change_warning).to be_nil
    end

    it 'warns using the piece price when a PC line genuinely changed' do
      create(:order_item, order: order, supplier_product: supplier_product, uom: 'PC', quantity: 1, unit_price: 80.00)

      warning = price_change_warning
      expect(warning).to be_present
      change = warning[:details][:changes].first
      expect(change[:old_price]).to eq(80.00)
      expect(change[:new_price]).to eq(85.48) # piece price, not the 466.32 case price
    end

    it 'still warns on a real case-price change' do
      create(:order_item, order: order, supplier_product: supplier_product, uom: 'CS', quantity: 1, unit_price: 400.00)

      warning = price_change_warning
      expect(warning).to be_present
      expect(warning[:details][:changes].first[:new_price]).to eq(466.32)
    end
  end
end
