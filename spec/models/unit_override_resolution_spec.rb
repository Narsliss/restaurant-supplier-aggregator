require "rails_helper"

# The resolution ladder in UnitComparable#comparison_per_oz:
#   1. a weight a chef set for this exact pack
#   2. the platform estimate (ProduceWeightEstimator)
#   3. the supplier's own weight or volume
#   4. nothing — the line stays incomparable
RSpec.describe "Chef pack weights in the comparison ladder" do
  let(:organization) { create(:organization) }
  let(:boston) { create(:location, organization: organization, name: "Boston") }
  let(:california) { create(:location, organization: organization, name: "California") }
  let(:supplier) { create(:supplier, name: "Chef's Warehouse") }

  def item_at(location, pack_size: "1 BUSHEL", price: 32.00, sku: "SKU-1", name: "Green Bell Peppers")
    list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
    # supplier_products are unique per (supplier, sku) — both cities buy the
    # same catalogue product, which is the point.
    sp = SupplierProduct.find_or_initialize_by(supplier: supplier, supplier_sku: sku)
    sp.update!(supplier_name: name, pack_size: pack_size, current_price: price, in_stock: true)
    create(:supplier_list_item, supplier_list: list, name: name, sku: sku,
                                pack_size: pack_size, price: price, supplier_product: sp)
  end

  def set_weight(oz, location: nil, sku: "SKU-1", fingerprint: "1 BUSHEL")
    UnitOverride.create!(organization: organization, supplier: supplier, location: location,
                         supplier_sku: sku, basis: "per_pack", net_weight_oz: oz,
                         pack_size_fingerprint: fingerprint)
  end

  it "uses a chef's weight and still marks the result an estimate" do
    set_weight(448) # 28 lb
    result = item_at(boston).comparison_per_oz

    expect(result[:value]).to eq((32.00 / 448).round(4))
    expect(result[:estimated]).to be(true)
    expect(result[:source]).to eq(:chef)
  end

  # ProduceWeightEstimator puts a bell pepper at 0.45 lb, which is a decent
  # guess and still a guess. The chef who takes the delivery outranks it.
  it "outranks the platform's own guess on a count pack" do
    guessed = item_at(boston, pack_size: "24 CT").comparison_per_oz
    expect(guessed[:estimated]).to be(true)
    expect(guessed[:source]).to be_nil

    # 8 oz a pepper rather than the table's 7.2
    UnitOverride.create!(organization: organization, supplier: supplier, supplier_sku: "SKU-2",
                         basis: "per_piece", net_weight_oz: 8, pack_size_fingerprint: "24 CT")
    corrected = item_at(california, pack_size: "24 CT", sku: "SKU-2").comparison_per_oz

    expect(corrected[:source]).to eq(:chef)
    expect(corrected[:value]).to eq((32.00 / 192).round(4))
    expect(corrected[:value]).not_to eq(guessed[:value])
  end

  describe "a restaurant group with rooms in two cities" do
    it "applies an org-wide weight at every location" do
      set_weight(448)

      expect(item_at(boston).chef_pack_weight_oz).to eq(448.0)
      expect(item_at(california).chef_pack_weight_oz).to eq(448.0)
    end

    it "lets one city's weight win over the group default" do
      set_weight(448)                      # the group says 28 lb
      set_weight(320, location: boston)    # Boston's box is really 20 lb

      expect(item_at(boston).chef_pack_weight_oz).to eq(320.0)
      expect(item_at(california).chef_pack_weight_oz).to eq(448.0)
    end

    it "keeps one location's weight out of another's when only that city has set one" do
      set_weight(320, location: boston)

      expect(item_at(boston).chef_pack_weight_oz).to eq(320.0)
      expect(item_at(california).chef_pack_weight_oz).to be_nil
    end
  end

  describe "when the supplier changes the pack" do
    it "goes dormant rather than carrying a weight that no longer fits the box" do
      set_weight(448, fingerprint: "1 BUSHEL")
      item = item_at(boston, pack_size: "20 LB")

      expect(item.unit_override).to be_present
      expect(item.unit_override_stale?).to be(true)
      expect(item.chef_pack_weight_oz).to be_nil
      # Falls back down the ladder — the supplier stated a weight, so the line
      # compares exactly and needs no estimate at all.
      expect(item.comparison_per_oz[:estimated]).to be(false)
    end

    it "survives the supplier merely renaming the same pack" do
      set_weight(448, fingerprint: "1 BUSHEL")
      item = item_at(boston, pack_size: "1 BU")

      expect(item.unit_override_stale?).to be(false)
      expect(item.chef_pack_weight_oz).to eq(448.0)
    end
  end
end
