require 'rails_helper'

RSpec.describe Catalog::BasketCandidateMatcher do
  def supplier(name)
    Supplier.find_or_create_by!(code: name.parameterize) do |s|
      s.name = name
      s.base_url = "https://example.test"
      s.login_url = "https://example.test/login"
      s.scraper_class = "Scrapers::BaseScraper"
    end
  end

  def product(sup, name:, pack: "12/1 LB", price: 50.0)
    SupplierProduct.create!(supplier: sup, supplier_sku: "#{name}-#{sup.id}".parameterize,
                            supplier_name: name, pack_size: pack, current_price: price)
  end

  let(:org) { create(:organization) }
  let(:chef) { create(:user, current_organization: org) }
  let(:cw) { supplier("Basket Warehouse") }
  let(:usf) { supplier("Basket Foods") }

  def order_line(sp)
    order = Order.create!(organization: org, user: chef, supplier: sp.supplier, status: "submitted")
    order.order_items.create!(supplier_product: sp, quantity: 1, unit_price: sp.current_price,
                              line_total: sp.current_price, product_name: sp.supplier_name)
    order
  end

  it 'links a bought product to the same product at another supplier' do
    bought = product(cw,  name: "Butter Unsalted Solid")
    peer   = product(usf, name: "Butter Unsalted Solid AA", price: 52.0)
    order_line(bought)

    result = described_class.new(org).call

    expect(result.products_examined).to eq(1)
    expect(result.products_matched).to eq(1)
    expect(ComparisonCandidate.pluck(:candidate_supplier_product_id)).to eq([peer.id])
  end

  # Regression. upsert_all listed updated_at in update_only, but Rails already
  # adds it to the SET clause, so Postgres rejected the whole statement with
  # "multiple assignments to same column". It only surfaced on a real run.
  it 'can be run twice without blowing up' do
    bought = product(cw,  name: "Butter Unsalted Solid")
    product(usf, name: "Butter Unsalted Solid AA", price: 52.0)
    order_line(bought)

    described_class.new(org).call
    expect { described_class.new(org).call }.not_to raise_error
    expect(ComparisonCandidate.count).to eq(1)
  end

  it 'refreshes the similarity of a pair it has already seen' do
    bought = product(cw, name: "Butter Unsalted Solid")
    product(usf, name: "Butter Unsalted Solid AA", price: 52.0)
    order_line(bought)

    described_class.new(org).call
    ComparisonCandidate.update_all(similarity: 0.01)
    described_class.new(org).call

    expect(ComparisonCandidate.first.similarity.to_f).to be > 0.5
  end

  it 'never pairs a product with its own supplier' do
    bought = product(cw, name: "Butter Unsalted Solid")
    product(cw, name: "Butter Unsalted Solid AA", price: 52.0)
    order_line(bought)

    expect(described_class.new(org).call.candidates_written).to eq(0)
  end

  it 'skips a peer measured in a different unit' do
    bought = product(cw,  name: "Gloves Nitrile Small", pack: "4/250 EA")
    product(usf, name: "Gloves Nitrile Small Black", pack: "10 LB", price: 40.0)
    order_line(bought)

    expect(described_class.new(org).call.candidates_written).to eq(0)
  end

  it 'ignores products the organization has never ordered' do
    product(cw,  name: "Butter Unsalted Solid")
    product(usf, name: "Butter Unsalted Solid AA", price: 52.0)

    expect(described_class.new(org).call.products_examined).to eq(0)
  end
end
