require 'rails_helper'

# Chef's Warehouse half & half (DM132, "12x1 QT Piece", $2.63 a piece) sat at
# $54,535.68 = $2.63 x 12^4 in production on Oct 20 2026. A guide row with no
# price of its own borrowed the product's case price, and the per-piece case
# math multiplied it by 12 again on every such sync. The extreme-change guard
# let each x12 through as a pack multiple and refused the real price coming
# back down (docs/fix-compounding-piece-prices.md).
RSpec.describe ImportSupplierListsService, 'compounding piece prices' do
  let(:supplier) { create(:supplier) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:list) do
    SupplierList.create!(supplier: supplier, supplier_credential: credential,
                         organization_id: credential.organization_id, name: 'Order Guide')
  end
  let(:service) { described_class.new(credential) }
  let!(:product) do
    SupplierProduct.create!(supplier: supplier, supplier_sku: 'DM132', supplier_name: 'Ultra Pasteurized Half & Half',
                            current_price: 31.56, pack_size: '12x1 QT Piece')
  end

  def guide_row(price)
    list.supplier_list_items.create!(name: 'Ultra Pasteurized Half & Half', sku: 'DM132', price: price,
                                     pack_size: '12x1 QT Piece', supplier_product_id: product.id)
  end

  it 'leaves the product price alone, sync after sync, when the guide sent no price' do
    row = guide_row(nil)

    3.times { service.send(:refresh_linked_product, row.reload) }

    expect(product.reload.current_price.to_f).to eq(31.56) # was 378.72, 4,544.64, 54,535.68
  end

  it 'still shows the product price on a guide row that has none' do
    expect(guide_row(nil).effective_price.to_f).to eq(31.56)
  end

  it 'still turns the guide piece price into the case price' do
    product.update!(current_price: 2.63) # the weekly re-price writes the piece price
    service.send(:refresh_linked_product, guide_row(2.63))

    expect(product.reload.current_price.to_f).to eq(31.56)
  end

  it "lets the guide's real price bring an inflated product back down" do
    product.update!(current_price: 54_535.68)
    service.send(:refresh_linked_product, guide_row(2.63))

    expect(product.reload.current_price.to_f).to eq(31.56)
  end

  describe 'the extreme-change guard' do
    it 'allows a drop by the pack size squared or more (undoing compounding)' do
      expect(service.send(:extreme_price_change?, 54_535.68, 31.56, '12x1 QT Piece')).to be(false)
      expect(service.send(:extreme_price_change?, 4_544.64, 31.56, '12x1 QT Piece')).to be(false)
    end

    it 'still blocks a drop by just the pack size' do
      expect(service.send(:extreme_price_change?, 31.56, 2.63, '12x1 QT Piece')).to be(true)
    end

    it 'still blocks a collapse that is no power of the pack size' do
      expect(service.send(:extreme_price_change?, 1000.0, 3.0, '12x1 QT Piece')).to be(true)
    end
  end

  describe 'the email price list import (same pattern)' do
    it 'leaves the product price alone when the price list sent no price' do
      row = guide_row(nil)

      ImportEmailPriceListService.new(nil, supplier, [], nil).send(:refresh_linked_product, row)

      expect(product.reload.current_price.to_f).to eq(31.56)
    end
  end
end
