require 'rails_helper'

RSpec.describe UnitParser do
  describe '.parse' do
    it 'returns parseable=false for blank input' do
      expect(UnitParser.parse(nil)).to eq(parseable: false)
      expect(UnitParser.parse('')).to eq(parseable: false)
      expect(UnitParser.parse('   ')).to eq(parseable: false)
    end

    context 'simple weight' do
      it 'parses "50 LB"' do
        result = UnitParser.parse('50 LB')
        expect(result).to include(quantity: 50.0, unit: 'lb', normalized_unit: 'oz', parseable: true)
        expect(result[:normalized_quantity]).to eq(800.0)
      end

      it 'parses "16 oz"' do
        result = UnitParser.parse('16 oz')
        expect(result[:normalized_quantity]).to eq(16.0)
        expect(result[:normalized_unit]).to eq('oz')
      end

      it 'parses "5lb" (no space)' do
        expect(UnitParser.parse('5lb')[:normalized_quantity]).to eq(80.0)
      end
    end

    context 'volume' do
      it 'parses "1 GAL" as 128 fl oz' do
        result = UnitParser.parse('1 GAL')
        expect(result[:normalized_quantity]).to eq(128.0)
        expect(result[:normalized_unit]).to eq('fl oz')
      end

      it 'parses "G" as gallons (food-service convention)' do
        result = UnitParser.parse('1 G')
        expect(result[:normalized_unit]).to eq('fl oz')
        expect(result[:normalized_quantity]).to eq(128.0)
      end
    end

    context 'count and dozen' do
      it 'parses "15 DZ" as 180 each' do
        result = UnitParser.parse('15 DZ')
        expect(result[:normalized_quantity]).to eq(180.0)
        expect(result[:normalized_unit]).to eq('each')
      end

      it 'parses "1 DOZEN" as 12 each' do
        result = UnitParser.parse('1 DOZEN')
        expect(result[:normalized_quantity]).to eq(12.0)
      end
    end

    context 'case packs' do
      it 'parses "4x10 oz" as 40 oz' do
        expect(UnitParser.parse('4x10 oz')[:normalized_quantity]).to eq(40.0)
      end

      it 'parses "Case - 12-2#" as 24 lb (384 oz)' do
        result = UnitParser.parse('Case - 12-2#')
        expect(result[:normalized_quantity]).to eq(384.0)
      end

      it 'parses "12/2 LB" as 24 lb' do
        result = UnitParser.parse('12/2 LB')
        expect(result[:quantity]).to eq(24.0)
      end

      it 'parses triple-number "8/2/1.9 LB" as 8 × 1.9 = 15.2 lb' do
        result = UnitParser.parse('8/2/1.9 LB')
        expect(result[:quantity]).to be_within(0.001).of(15.2)
      end
    end

    context 'pound sign and weight qualifier suffixes' do
      it 'parses "40#" as 40 lb' do
        expect(UnitParser.parse('40#')[:normalized_quantity]).to eq(640.0)
      end

      it 'strips US Foods average suffixes ("LBA" → "LB", "OZA" → "OZ")' do
        result = UnitParser.parse('1 LBA')
        expect(result[:unit]).to eq('lb')
      end

      it 'strips weight qualifiers like "5#UP", "10#avg", "15 lb+"' do
        # "4 5#UP" should parse as 4 × 5 lb = 20 lb (320 oz)
        expect(UnitParser.parse('4 5#UP')[:normalized_quantity]).to eq(320.0)
        # "1 10#avg" should parse as 10 lb (160 oz)
        expect(UnitParser.parse('1 10#avg')[:normalized_quantity]).to eq(160.0)
      end
    end

    context 'fractions on bushels' do
      it 'parses "1/2 BUSHEL" as 0.5 bushels' do
        result = UnitParser.parse('1/2 BUSHEL')
        expect(result[:quantity]).to eq(0.5)
      end

      it 'parses "1-1/9 BUSH" as ~1.111 bushels' do
        result = UnitParser.parse('1-1/9 BUSH')
        expect(result[:quantity]).to be_within(0.001).of(1.111)
      end
    end

    context 'bare units' do
      it 'parses "BUNCH" as 1 bunch' do
        result = UnitParser.parse('BUNCH')
        expect(result).to include(quantity: 1.0, normalized_unit: 'bunch')
      end
    end

    context 'count ranges (produce sizing)' do
      it 'treats "80/88 CT" as a size range, returning the average' do
        result = UnitParser.parse('80/88 CT')
        expect(result[:quantity]).to eq(84.0)
      end

      it 'treats "18/20 EA" as a case pack (small counts), not a range' do
        result = UnitParser.parse('18/20 EA')
        expect(result[:quantity]).to eq(360.0)
      end
    end
  end

  describe '.per_unit_price' do
    it 'returns price / normalized_quantity, rounded to 4 decimals' do
      expect(UnitParser.per_unit_price(40.0, '5 LB')).to eq(0.5) # $40 / 80 oz
    end

    it 'returns nil when pack_size is unparseable' do
      expect(UnitParser.per_unit_price(10.0, 'gibberish')).to be_nil
    end

    it 'returns nil when price is nil' do
      expect(UnitParser.per_unit_price(nil, '5 LB')).to be_nil
    end
  end

  describe '.per_piece_normalized' do
    it 'returns the normalized quantity per piece for a multiplied pack' do
      result = UnitParser.per_piece_normalized('4x1 gallon')
      expect(result).to eq(quantity: 128.0, unit: 'fl oz')
    end

    it 'returns nil for non-case-pack formats' do
      expect(UnitParser.per_piece_normalized('50 LB')).to be_nil
    end
  end

  describe '.comparable?' do
    it 'is true when both pack sizes share the same normalized unit' do
      expect(UnitParser.comparable?('5 LB', '32 OZ')).to be true
    end

    it 'is false across unit categories' do
      expect(UnitParser.comparable?('5 LB', '1 GAL')).to be false
    end

    it 'is false when one side is unparseable' do
      expect(UnitParser.comparable?('5 LB', 'gibberish')).to be false
    end
  end

  describe '.estimated_total' do
    it 'returns the price as-is when price_unit is blank' do
      expect(UnitParser.estimated_total(45.00, nil, '50 LB')).to eq(45.00)
    end

    it 'multiplies when price unit matches pack unit (e.g., $/lb × pack lbs)' do
      expect(UnitParser.estimated_total(16.54, 'lb', '12/6 LBA')).to eq(1190.88)
    end

    it 'converts when price unit differs from pack unit' do
      # $0.50/oz × 5 lb (80 oz) = $40
      expect(UnitParser.estimated_total(0.50, 'oz', '5 LB')).to eq(40.0)
    end
  end

  describe '.format_per_unit' do
    it 'formats values >= $1 with 2 decimals' do
      expect(UnitParser.format_per_unit(2.5, 'oz')).to eq('$2.50/oz')
    end

    it 'formats values < $0.01 with 4 decimals' do
      expect(UnitParser.format_per_unit(0.0034, 'oz')).to eq('$0.0034/oz')
    end

    it 'returns nil when either argument is nil' do
      expect(UnitParser.format_per_unit(nil, 'oz')).to be_nil
      expect(UnitParser.format_per_unit(2.5, nil)).to be_nil
    end
  end
end
