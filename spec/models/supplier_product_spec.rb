require 'rails_helper'

RSpec.describe SupplierProduct, type: :model do
  # Regression: US Foods catch-weight items (order #145 pork) store the per-LB
  # price in current_price with price_unit "LB". Order lines are priced per
  # case — using the raw figure priced a ~$100 case at $2.00.
  describe '#estimated_case_price' do
    it 'converts a per-LB price to the full case cost' do
      sp = build(:supplier_product, current_price: 2.00, price_unit: 'LB', pack_size: '4/10 LB')
      expect(sp.estimated_case_price).to eq(80.00)
    end

    it 'returns the raw price for case-priced items (CS)' do
      sp = build(:supplier_product, current_price: 32.19, price_unit: 'CS', pack_size: '12/200 EA')
      expect(sp.estimated_case_price).to eq(32.19)
    end

    it 'returns the raw price for count units (EA) — price already covers the pack' do
      sp = build(:supplier_product, current_price: 15.00, price_unit: 'EA', pack_size: '12/200 EA')
      expect(sp.estimated_case_price).to eq(15.00)
    end

    it 'returns the raw price when price_unit is blank' do
      sp = build(:supplier_product, current_price: 45.00, price_unit: nil, pack_size: '50 LB')
      expect(sp.estimated_case_price).to eq(45.00)
    end

    it 'returns the raw price when the pack size is unparseable' do
      sp = build(:supplier_product, current_price: 2.00, price_unit: 'LB', pack_size: 'WHOLE HOG')
      expect(sp.estimated_case_price).to eq(2.00)
    end

    it 'converts an explicit price/unit pair (used for verified prices)' do
      sp = build(:supplier_product, current_price: 2.00, price_unit: 'LB', pack_size: '4/10 LB')
      expect(sp.estimated_case_price(price: 2.50, unit: 'LB')).to eq(100.00)
    end
  end

  # Regression: the price-comparison page computed pork at $2.00 ÷ 796.8 oz
  # (pack quantity) = a fictional $0.0025/oz. When the stored price is
  # per-unit, the per-oz price comes from the unit factor.
  describe '#per_unit_price with a per-unit price_unit' do
    it 'derives $/oz from the unit factor for per-LB prices' do
      sp = build(:supplier_product, current_price: 2.00, price_unit: 'LB', pack_size: '4/10 LB')
      expect(sp.per_unit_price).to eq(0.125)
    end

    it 'divides by pack quantity for case-priced items as before' do
      sp = build(:supplier_product, current_price: 32.00, price_unit: 'CS', pack_size: '4/10 LB')
      expect(sp.per_unit_price).to eq((32.00 / 640).round(4))
    end
  end

  describe '#priced_per_weight?' do
    it 'is true for weight price units' do
      expect(build(:supplier_product, price_unit: 'LB').priced_per_weight?).to be true
    end

    it 'is false for case and count units and blank' do
      expect(build(:supplier_product, price_unit: 'CS').priced_per_weight?).to be false
      expect(build(:supplier_product, price_unit: 'EA').priced_per_weight?).to be false
      expect(build(:supplier_product, price_unit: nil).priced_per_weight?).to be false
    end
  end
end
