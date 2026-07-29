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

  # Chef report (mobile testing 2026-07): "per piece comparisons vs oz mostly
  # on veggies" — count-vs-weight produce either dropped suppliers from the
  # comparison or showed $/ea next to $/oz.
  describe 'mixed count-vs-weight produce comparison' do
    it 'compares ALL suppliers of baker potatoes (50 LB cases vs 70 CT cases)' do
      by_weight = add_supplier_item(price: 27.83, pack_size: '50 LB', name: 'BAKER POTATOES 50lb')
      by_count = add_supplier_item(price: 26.98, pack_size: '1x70 Count Case', name: 'Baker Potato 70ct')

      group = match.comparable_group
      expect(group.size).to eq(2)
      expect(match.per_unit_comparable?).to be true

      # 50 LB at $27.83 → $0.0348/oz. 70 ct at ~0.7 lb each → $0.0344/oz est.
      # The count supplier is (just) cheaper — previously it was excluded or
      # arbitrary depending on group sizes.
      cheapest = match.cheapest_supplier
      expect(cheapest[:item]).to eq(by_count)
      expect(group.find { |p| p[:item] == by_count }[:comparison_estimated]).to be true
      expect(group.find { |p| p[:item] == by_weight }[:comparison_estimated]).to be false
    end

    it 'includes the weight-based supplier of limes among count-based ones' do
      add_supplier_item(price: 15.61, pack_size: '48 EA', name: 'Limes 48ct')
      by_weight = add_supplier_item(price: 14.29, pack_size: '1x10 LB Case', name: 'lime 10 lb case')

      group = match.comparable_group
      expect(group.size).to eq(2)
      # $14.29 / 160 oz = $0.089/oz vs 48 limes ≈ $0.325/ea ÷ 3.2 oz = $0.102/oz
      expect(match.cheapest_supplier[:item]).to eq(by_weight)
    end

    it 'compares cherry tomato pints against count baskets 1:1' do
      pints = add_supplier_item(price: 40.70, pack_size: '12 PT CS', name: 'Tomato Cherry Heirloom pints')
      counts = add_supplier_item(price: 25.54, pack_size: '1x12 Count Case', name: 'Tomato Cherry Heirloom counts')

      group = match.comparable_group
      expect(group.size).to eq(2)
      # Both are 12 baskets ≈ 0.75 lb each — the $25.54 case wins
      expect(match.cheapest_supplier[:item]).to eq(counts)
    end

    it 'leaves homogeneous count matches on exact per-each comparison (no ~est display)' do
      a = add_supplier_item(price: 15.61, pack_size: '48 EA', name: 'Limes 48ct A')
      b = add_supplier_item(price: 16.35, pack_size: '48 CT', name: 'Limes 48ct B')

      group = match.comparable_group
      expect(group.size).to eq(2)
      expect(group.all? { |p| p[:comparison_estimated] == false }).to be true
      expect(match.display_per_unit_for(a)).to eq(a.formatted_per_unit_price)
      expect(match.cheapest_supplier[:item]).to eq(a)
    end

    it 'does not convert unrecognized products — non-produce keeps same-unit grouping' do
      add_supplier_item(price: 63.76, pack_size: '24/1 EA', name: 'Chafing Fuel 6hr')
      add_supplier_item(price: 57.90, pack_size: '24x8 Oz Case', name: 'Chafing Fuel 8oz cans')

      # Units mixed but nothing convertible with confidence → falls back to
      # largest same-unit group (size 1 each → not comparable)
      expect(match.per_unit_comparable?).to be false
    end

    it 'shows the ~est marker for converted entries' do
      add_supplier_item(price: 27.83, pack_size: '50 LB', name: 'BAKER POTATOES 50lb')
      by_count = add_supplier_item(price: 26.98, pack_size: '1x70 Count Case', name: 'Baker Potato 70ct')

      # (String#match? because `let(:match)` shadows RSpec's match matcher)
      expect(match.display_per_unit_for(by_count).match?(/\A~\$0\.03\d*\/oz est\z/)).to be true
    end
  end
end
