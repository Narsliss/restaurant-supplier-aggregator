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

  # Regression (Oct 2026, caught before deploy): scrapers now return nil for
  # "can't tell", and update_price! used to write it, which reads as out of
  # stock (out_of_stock? is !in_stock). VerifyItemPriceJob, ScrapeSupplierJob
  # and QuickPriceUpdateService all pass the scraper's value straight in.
  describe '#update_price!' do
    it 'keeps the stock flag when the supplier did not say (nil)' do
      sp = create(:supplier_product, current_price: 10.0, in_stock: false)
      sp.update_price!(11.0, in_stock: nil)
      expect(sp.reload).to have_attributes(current_price: 11.0, in_stock: false)

      sp.update!(in_stock: true)
      sp.update_price!(12.0, in_stock: nil)
      expect(sp.reload.in_stock).to be(true)
    end

    it 'still writes a definite answer' do
      sp = create(:supplier_product, current_price: 10.0, in_stock: true)
      sp.update_price!(11.0, in_stock: false)
      expect(sp.reload.in_stock).to be(false)
    end
  end

  describe '#record_live_stock!' do
    let(:sp) { create(:supplier_product, in_stock: true) }

    it 'saves a live "out" and the reading' do
      sp.record_live_stock!(false, signal: '0.0')
      expect(sp.reload).to have_attributes(in_stock: false, stock_signal: '0.0', stock_source: 'price_check')
      expect(sp.stock_checked_at).to be_within(1.minute).of(Time.current)
    end

    it 'records the reading even when the flag is unchanged' do
      sp.record_live_stock!(true, signal: '8.0')
      expect(sp.reload).to have_attributes(in_stock: true, stock_signal: '8.0')
      expect(sp.stock_checked_at).to be_present
    end

    it 'changes nothing on nil' do
      sp.record_live_stock!(nil, signal: 'whatever')
      expect(sp.reload).to have_attributes(in_stock: true, stock_signal: nil, stock_checked_at: nil)
    end
  end
end
