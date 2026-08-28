require "rails_helper"

# The boundary the whole feature rests on, enforced rather than commented.
#
# A chef's pack weight may change what is SHOWN and how suppliers are RANKED.
# It must never change what is SUBMITTED, what a recipe COSTS, or what the
# platform CLAIMS it saved anyone. That holds structurally, because the override
# supplies comparison_per_oz alone and every one of those other paths reads the
# raw fields it never touches — this spec is what keeps it true as the code moves.
RSpec.describe "Chef pack weights stay out of ordering and costing" do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:supplier) { create(:supplier, name: "Chef's Warehouse") }

  let(:item) do
    list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
    sp = create(:supplier_product, supplier: supplier, supplier_sku: "SKU-1",
                                   pack_size: "1 BUSHEL", current_price: 32.00, in_stock: true)
    create(:supplier_list_item, supplier_list: list, name: "Green Bell Peppers", sku: "SKU-1",
                                pack_size: "1 BUSHEL", price: 32.00, supplier_product: sp)
  end

  def set_weight(oz)
    UnitOverride.create!(organization: organization, supplier: supplier, supplier_sku: "SKU-1",
                         basis: "per_pack", net_weight_oz: oz, pack_size_fingerprint: "1 BUSHEL")
  end

  # The override lookup is memoized per object, and per SupplierList, so a
  # single request never re-queries it. Re-fetching is what makes these
  # assertions mean anything — reload alone keeps the memo and every "unchanged"
  # expectation below would pass without proving a thing.
  def fresh
    SupplierListItem.find(item.id)
  end

  it "gives the line a comparison basis it did not have, which is the whole point" do
    # A bushel is a size of container, not a weight. Without a chef there is
    # nothing honest to compare it on.
    expect(fresh.comparison_per_oz).to be_nil

    set_weight(448)
    expect(fresh.comparison_per_oz[:value]).to eq((32.00 / 448).round(4))
  end

  # Everything below must be identical either side of that weight existing.
  {
    "the price a chef is charged" => :price,
    "the case-equivalent price an order line is built from" => :estimated_total_price,
    "the per-unit price recipe costing reads" => :per_unit_price,
    "the unit recipe costing matches on" => :normalized_unit
  }.each do |description, method|
    it "leaves #{description} untouched" do
      before_value = fresh.public_send(method)
      set_weight(448)
      expect(fresh.public_send(method)).to eq(before_value)
    end
  end

  it "never reaches the order line's unit price, even at an absurd weight" do
    # The exact expression Orders::AggregatedListOrderService builds a line from.
    priced = -> { i = fresh; i.estimated_total_price || i.price }

    before_value = priced.call
    set_weight(2)
    expect(priced.call).to eq(before_value)
  end

  it "is absent from the order placement path entirely" do
    source = File.read(Rails.root.join("app/services/orders/order_placement_service.rb"))

    expect(source).not_to include("UnitOverride")
    expect(source).not_to include("comparison_per_oz")
    expect(source).not_to include("chef_pack_weight_oz")
  end
end
