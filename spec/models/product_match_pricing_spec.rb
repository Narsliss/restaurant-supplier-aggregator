require 'rails_helper'

# Regression: order #145 — when suppliers aren't per-unit comparable, the
# cheapest/most-expensive pick compared RAW prices, so a catch-weight item's
# per-LB price ($2.00) always beat real case prices, and builder totals used
# the per-LB figure as the case cost.
RSpec.describe ProductMatch, type: :model do
  let(:match) { create(:product_match) }

  def add_supplier_item(price:, price_unit: nil, pack_size: '1 case', name: 'Item')
    sli = create(:supplier_list_item,
                 name: name,
                 price: price,
                 price_unit: price_unit,
                 pack_size: pack_size,
                 supplier_product: create(:supplier_product, current_price: price, price_unit: price_unit, pack_size: pack_size))
    create(:product_match_item, product_match: match, supplier_list_item: sli)
    sli
  end

  describe '#prices_by_supplier' do
    it 'exposes estimated_price as the case-equivalent for catch-weight items' do
      add_supplier_item(price: 2.00, price_unit: 'LB', pack_size: '4/10 LB', name: 'Pork per-lb')

      entry = match.prices_by_supplier.first
      expect(entry[:price]).to eq(2.00)
      expect(entry[:estimated_price]).to eq(80.00)
    end
  end

  describe '#cheapest_supplier without per-unit comparability' do
    it 'compares case-equivalents so a raw per-LB price does not always win' do
      # Unparseable packs ⇒ no per_unit_price ⇒ non-comparable branch
      pork = add_supplier_item(price: 2.00, price_unit: 'LB', pack_size: '4/10 LB', name: 'Pork per-lb')
      cheap_case = add_supplier_item(price: 65.00, price_unit: nil, pack_size: 'MARKET PACK', name: 'Pork case')

      allow(match).to receive(:per_unit_comparable?).and_return(false)

      expect(match.cheapest_supplier[:item]).to eq(cheap_case)
      expect(match.most_expensive_supplier[:item]).to eq(pork)
    end
  end
end
