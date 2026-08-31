require 'rails_helper'
require 'ostruct'

# These specs exercise the classifiers via duck-typed structs rather than
# building real SupplierListItem records — the classifiers only need
# `pack_size`, `price`, `price_unit`, `source`, and `supplier` (with `.code`
# and `.case_pricing?`).

RSpec.describe PriceClassifiers::Base do
  def make_item(supplier_code:, case_pricing: true, pack_size: '', price: 10.0, price_unit: nil, source: 'list_import')
    supplier = OpenStruct.new(code: supplier_code, case_pricing?: case_pricing)
    OpenStruct.new(
      supplier: supplier,
      pack_size: pack_size,
      price: price,
      price_unit: price_unit,
      source: source
    )
  end

  describe '.for' do
    it 'returns the registered classifier for a known code' do
      item = make_item(supplier_code: 'usfoods')
      expect(described_class.for(item)).to be_a(PriceClassifiers::UsFoods)
    end

    it 'falls back to Base for unknown codes' do
      item = make_item(supplier_code: 'unknown', case_pricing: false)
      expect(described_class.for(item)).to be_an_instance_of(PriceClassifiers::Base)
    end
  end

  describe '#inferred_price_unit (Base behavior)' do
    it 'returns nil when pack_size is blank' do
      item = make_item(supplier_code: 'usfoods', pack_size: '')
      expect(described_class.new(item).inferred_price_unit).to be_nil
    end

    it 'detects "LB+" → "lb"' do
      item = make_item(supplier_code: 'usfoods', pack_size: '15 LB+')
      expect(described_class.new(item).inferred_price_unit).to eq('lb')
    end

    it 'detects "10#avg" → "lb"' do
      item = make_item(supplier_code: 'sysco', pack_size: '10#avg')
      expect(described_class.new(item).inferred_price_unit).to eq('lb')
    end

    it 'detects "5#UP" → "lb"' do
      item = make_item(supplier_code: 'usfoods', pack_size: '5#UP')
      expect(described_class.new(item).inferred_price_unit).to eq('lb')
    end

    it 'returns nil for fixed-weight pack sizes' do
      item = make_item(supplier_code: 'usfoods', pack_size: '5 LB')
      expect(described_class.new(item).inferred_price_unit).to be_nil
    end

    it 'skips inference when price is blank on a case-pricing supplier' do
      item = make_item(supplier_code: 'chefswarehouse', case_pricing: true, price: nil, pack_size: '10#avg')
      expect(described_class.for(item).inferred_price_unit).to be_nil
    end

    it 'skips inference when source is catalog_search on a case-pricing supplier' do
      item = make_item(supplier_code: 'chefswarehouse', case_pricing: true, source: 'catalog_search', pack_size: '10#avg')
      expect(described_class.for(item).inferred_price_unit).to be_nil
    end

    # Suppliers write the variable-weight marker with a space, a hyphen, or
    # nothing at all. Requiring whitespace read Sysco's "12x5#-UP" beef
    # tenderloin as a fixed 60 lb case and spread a per-pound quote across it.
    {
      '12x5#-UP'   => 'lb',
      '5#-AVG'     => 'lb',
      '24x8OZAVG'  => 'oz',
      '10#-+'      => 'lb',
      '5# UP'      => 'lb',
      '4x16#AVG'   => 'lb',
      '12LB AVG'   => 'lb'
    }.each do |pack, unit|
      it "reads #{pack.inspect} as priced per #{unit}" do
        item = make_item(supplier_code: 'usfoods', case_pricing: false, pack_size: pack)
        expect(described_class.new(item).inferred_price_unit).to eq(unit)
      end
    end

    # A weight range says the same thing as AVG: each piece lands in a band, so
    # the price is a rate per pound. Sysco writes its catch-weight proteins this
    # way far more often than it writes AVG, and reading them as case totals put
    # whole chickens at $0.04/lb and boneless pork butt at $0.03/lb.
    ['14x3-3.50 LB', '8x7-10# LB', '2x10-14# LB', '16x2.5-3# LB', '16x3-3.5# LB', '2x5-7#'].each do |pack|
      it "reads the weight range in #{pack.inspect} as priced per lb" do
        item = make_item(supplier_code: 'usfoods', case_pricing: false, pack_size: pack)
        expect(described_class.new(item).inferred_price_unit).to eq('lb')
      end
    end

    # PPO writes "BAG - 1-5#" and "CASE - 1-10#", where the leading 1 is a
    # container count and the pack really is case-priced. Anchoring the range on
    # the pack multiplier keeps those out; without it they inflated PPO case
    # costs and overstated the savings the fix was supposed to correct.
    # Each of these read wrong against real production rows before the range
    # pattern was narrowed. "1x18-24#" is ONE container weighing 18-24 lb, and
    # reading it per-pound put a case of zucchini at $586.95. "1x4-5 PC" counts
    # pieces. PPO's "BAG - 1-5#" leads with a container count.
    ['1x18-24#', '1x4-5 PC', 'BAG - 1-5#', 'CASE - 1-10#', 'CASE - 2-2.2#', 'EACH - 1-1 QT'].each do |pack|
      it "does not read a container count as a range in #{pack.inspect}" do
        item = make_item(supplier_code: 'usfoods', case_pricing: false, pack_size: pack)
        expect(described_class.new(item).inferred_price_unit).to be_nil
      end
    end

    ['5 LB', '12x12 OZ', '1x12 LB', '6/1 LB', '1x40LB', '1x30 LB'].each do |pack|
      it "leaves fixed-weight pack #{pack.inspect} alone" do
        item = make_item(supplier_code: 'usfoods', case_pricing: false, pack_size: pack)
        expect(described_class.new(item).inferred_price_unit).to be_nil
      end
    end
  end
end

RSpec.describe PriceClassifiers::Sysco do
  def make_sysco(pack_size:, price: 10.0, source: 'order_guide')
    supplier = OpenStruct.new(code: 'sysco', case_pricing?: true)
    OpenStruct.new(supplier: supplier, pack_size: pack_size, price: price,
                   price_unit: nil, source: source)
  end

  # Sysco quotes a catalog price the same way it quotes an order-guide price:
  # catch-weight items carry a rate per pound. Base skips catalog_search rows
  # on the assumption that a catalog price is a case price, which split the same
  # item two ways depending only on how it reached the list.
  it 'infers per-lb on a catalog_search row, as it does for an order guide' do
    %w[order_guide catalog_search].each do |source|
      item = make_sysco(pack_size: '16x1#AVG', source: source)
      expect(described_class.new(item).inferred_price_unit).to eq('lb'),
             "expected per-lb inference for source #{source}"
    end
  end

  it 'still skips inference when there is no price to label' do
    item = make_sysco(pack_size: '16x1#AVG', price: nil, source: 'catalog_search')
    expect(described_class.new(item).inferred_price_unit).to be_nil
  end

  it 'leaves a fixed-weight pack alone' do
    item = make_sysco(pack_size: '12x12 OZ', source: 'catalog_search')
    expect(described_class.new(item).inferred_price_unit).to be_nil
  end
end

RSpec.describe PriceClassifiers::WhatChefsWant do
  def make_wcw(pack_size:, price: 10.0, price_unit: nil, source: 'list_import')
    supplier = OpenStruct.new(code: 'whatchefswant', case_pricing?: true)
    OpenStruct.new(supplier: supplier, pack_size: pack_size, price: price, price_unit: price_unit, source: source)
  end

  it 'treats "- Each" suffix as per-lb pricing' do
    item = make_wcw(pack_size: '6LB AVG | Packer - Each')
    expect(described_class.new(item).inferred_price_unit).to eq('lb')
  end

  it 'treats "- Case" suffix as case-priced (skip)' do
    item = make_wcw(pack_size: '15 LB AVG | CATELLI BROS - Case')
    expect(described_class.new(item).inferred_price_unit).to be_nil
  end

  it 'treats LB-only formats without "- Each" suffix as case-priced' do
    item = make_wcw(pack_size: '6LB AVG')
    expect(described_class.new(item).inferred_price_unit).to be_nil
  end
end

RSpec.describe PriceClassifiers::PremiereProduceOne do
  def make_ppo(pack_size:, price: 10.0, price_unit: nil, source: 'list_import')
    supplier = OpenStruct.new(code: 'premiereproduceone', case_pricing?: true)
    OpenStruct.new(supplier: supplier, pack_size: pack_size, price: price, price_unit: price_unit, source: source)
  end

  it 'treats "Case - " prefix as case-priced (skip)' do
    item = make_ppo(pack_size: 'Case - 75# AVG', price_unit: 'each')
    expect(described_class.new(item).inferred_price_unit).to be_nil
  end

  it 'treats EACH-priced items with # weight and high implied $/lb as case-priced' do
    # $50 per "each" / 10 lb pack → $5/lb implied → looks like case price
    item = make_ppo(pack_size: '1-10#', price: 50.0, price_unit: 'each')
    expect(described_class.new(item).inferred_price_unit).to be_nil
  end

  it 'treats EACH-priced items with low implied $/lb as per-lb' do
    # $5 per "each" / 10 lb pack → $0.50/lb implied → per-lb pricing
    item = make_ppo(pack_size: '1-10#', price: 5.0, price_unit: 'each')
    expect(described_class.new(item).inferred_price_unit).to eq('lb')
  end
end

RSpec.describe PriceClassifiers::UsFoods do
  it 'inherits Base behavior (variable-weight LB+ detection)' do
    supplier = OpenStruct.new(code: 'usfoods', case_pricing?: false)
    item = OpenStruct.new(supplier: supplier, pack_size: '15 LB+', price: 10.0, price_unit: nil, source: 'list_import')
    expect(described_class.new(item).inferred_price_unit).to eq('lb')
  end
end
