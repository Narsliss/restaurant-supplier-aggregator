require 'rails_helper'

# A chef reads BEST as "this one is cheaper". That is only true when the
# suppliers quote in the same unit. Sysco selling by the sheet and US Foods
# selling by the ounce cannot be ranked without knowing the pack weight, so the
# badge has to be withheld rather than guessed at.
RSpec.describe ProductMatch, '.compare_by_unit' do
  def row(supplier_id, per_unit:, unit:)
    { supplier: Supplier.new(id: supplier_id), per_unit_price: per_unit, normalized_unit: unit }
  end

  it 'compares two suppliers quoting in the same unit' do
    rows = [row(1, per_unit: 0.12, unit: 'oz'), row(2, per_unit: 0.20, unit: 'oz')]

    verdict, group = described_class.compare_by_unit(rows)

    expect(verdict).to eq(:exact)
    expect(group.size).to eq(2)
  end

  it 'treats oz and fl oz as the same unit' do
    rows = [row(1, per_unit: 0.12, unit: 'oz'), row(2, per_unit: 0.20, unit: 'fl oz')]

    expect(described_class.compare_by_unit(rows).first).to eq(:exact)
  end

  it 'refuses to rank an each price against an ounce price' do
    rows = [row(1, per_unit: 0.12, unit: 'oz'), row(2, per_unit: 4.79, unit: 'each')]

    verdict, group = described_class.compare_by_unit(rows)

    expect(verdict).to eq(:incomparable)
    expect(group).to be_empty
  end

  it 'refuses to rank when a supplier has no per-unit price at all' do
    # Sheets, bushels and bare "1 CS" pack sizes yield no per-unit price.
    rows = [row(1, per_unit: nil, unit: nil), row(2, per_unit: 4.79, unit: 'each')]

    expect(described_class.compare_by_unit(rows).first).to eq(:incomparable)
  end

  it 'compares the largest same-unit group and leaves the odd unit out' do
    rows = [row(1, per_unit: 0.15, unit: 'oz'),
            row(2, per_unit: 0.21, unit: 'oz'),
            row(3, per_unit: 4.79, unit: 'each')]

    verdict, group = described_class.compare_by_unit(rows)

    expect(verdict).to eq(:exact)
    expect(group.map { |r| r[:supplier].id }).to contain_exactly(1, 2)
  end

  it 'reports a lone supplier as nothing to compare, not as a unit clash' do
    expect(described_class.compare_by_unit([row(1, per_unit: 0.12, unit: 'oz')]).first).to eq(:single)
    expect(described_class.compare_by_unit([]).first).to eq(:single)
  end

  it 'never converts between units to force a comparison' do
    # 24 CT at $0.83 each vs 6/10 LB at $0.02/oz — a conversion would rank
    # these; we deliberately do not, because the pack weight is unknown.
    rows = [row(1, per_unit: 0.83, unit: 'each'), row(2, per_unit: 0.02, unit: 'oz')]

    expect(described_class.compare_by_unit(rows).first).to eq(:incomparable)
  end
end
