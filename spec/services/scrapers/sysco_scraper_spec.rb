require 'rails_helper'

RSpec.describe Scrapers::SyscoScraper do
  # build_pack_size is pure (depends only on its argument), so we exercise it
  # via .allocate to avoid constructing a real credential / browser session.
  subject(:scraper) { described_class.allocate }

  describe '#build_pack_size' do
    def build(pack, size)
      scraper.send(:build_pack_size, { 'pack' => pack, 'size' => size })
    end

    it 'joins case count and per-unit size with an explicit "x" multiplier' do
      expect(build('12', '12 OZ')).to eq('12x12 OZ')
      expect(build('4', '3 LB')).to eq('4x3 LB')
      expect(build('6', '6 LB')).to eq('6x6 LB')
    end

    # Regression: "12 12 OZ" (12 bottles x 12 oz = 144 oz) was mis-parsed as a
    # single 12 oz unit, inflating per-unit price ~12x. The "x" form must parse
    # to the full case quantity.
    it 'produces a string UnitParser reads as the full case quantity (count == size)' do
      packed = build('12', '12 OZ')
      parsed = UnitParser.parse(packed)
      expect(parsed[:normalized_quantity]).to eq(144.0)
      expect(parsed[:normalized_unit]).to eq('oz')
      # $91.85 case → $0.64/oz, not $7.65/oz
      expect(UnitParser.per_unit_price(91.85, packed)).to eq(0.6378)
    end

    it 'does not regress non-equal case packs' do
      expect(UnitParser.parse(build('4', '3 LB'))[:normalized_quantity]).to eq(192.0)
    end

    it 'leaves catch-weight sizes (no count number) as a plain space join' do
      # size has no leading digit → must not become "40xLB"
      expect(build('40', 'LB')).to eq('40 LB')
    end

    it 'handles a missing pack count' do
      expect(build(nil, '12 OZ')).to eq('12 OZ')
      expect(build('', '12 OZ')).to eq('12 OZ')
    end

    it 'strips a duplicated trailing unit' do
      expect(build('4', '3 LB LB')).to eq('4x3 LB')
    end

    it 'returns nil for blank input' do
      expect(build(nil, nil)).to be_nil
      expect(build('', '')).to be_nil
    end
  end
end
