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
      item = make_item(supplier_code: 'sysco', case_pricing: true, price: nil, pack_size: '10#avg')
      expect(described_class.new(item).inferred_price_unit).to be_nil
    end

    it 'skips inference when source is catalog_search on a case-pricing supplier' do
      item = make_item(supplier_code: 'sysco', case_pricing: true, source: 'catalog_search', pack_size: '10#avg')
      expect(described_class.new(item).inferred_price_unit).to be_nil
    end
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
