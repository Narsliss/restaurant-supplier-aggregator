require "rails_helper"

# The shared product map (blueprint) adds each connected supplier to the rows
# it carries — not just the rows its order guide happens to hit. Additive and
# guarded; see ProductMapFillService.
RSpec.describe ProductMapFillService do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:list) do
    create(:aggregated_list, organization: organization, location_id: location.id, name: "alfios Matched List")
  end
  let(:usfoods) { create(:supplier, name: "US Foods Test", code: "usf-#{SecureRandom.hex(3)}") }
  let(:performance) { create(:supplier, name: "Performance Test", code: "pfg-#{SecureRandom.hex(3)}") }
  let(:usf_list) { create(:supplier_list, supplier: usfoods, organization: organization, location: location) }
  let(:pfg_list) { create(:supplier_list, supplier: performance, organization: organization, location: location) }

  let(:olive_oil) { create(:product, name: "Olive Oil Extra Virgin") }
  let(:usf_oil) { create(:supplier_product, supplier: usfoods, product: olive_oil, supplier_name: "USF OLIVE OIL EV") }
  let!(:pfg_oil) { create(:supplier_product, supplier: performance, product: olive_oil, supplier_name: "ROMA - OIL OLIVE EXTRA VIRGIN TIN") }

  def row(status: "confirmed", supplier_product: usf_oil, supplier_list: usf_list)
    pm = create(:product_match, aggregated_list: list, match_status: status, canonical_name: supplier_product.supplier_name)
    sli = create(:supplier_list_item, supplier_list: supplier_list, supplier_product: supplier_product, name: supplier_product.supplier_name)
    create(:product_match_item, product_match: pm, supplier_list_item: sli, supplier: supplier_product.supplier)
    pm
  end

  def performance_items(pm)
    pm.product_match_items.reload.select { |i| i.supplier_id == performance.id }
  end

  before do
    [usf_list, pfg_list].each { |sl| list.aggregated_list_mappings.find_or_create_by!(supplier_list: sl) }
  end

  it "adds the connected supplier's map product to a row that only had another supplier" do
    pm = row

    result = described_class.new(list).call

    added = performance_items(pm)
    expect(added.size).to eq(1)
    expect(added.first.supplier_list_item).to have_attributes(supplier_product_id: pfg_oil.id, source: "catalog_search",
                                                              supplier_list_id: pfg_list.id)
    expect(result.by_supplier).to eq(performance.id => 1)
  end

  it "keeps confirmed rows confirmed and promotes an unmatched row like catalog search does" do
    confirmed = row(status: "confirmed")
    other_oil = create(:product, name: "Canola")
    usf_canola = create(:supplier_product, supplier: usfoods, product: other_oil)
    create(:supplier_product, supplier: performance, product: other_oil)
    lonely = row(status: "unmatched", supplier_product: usf_canola)

    described_class.new(list).call

    expect(confirmed.reload.match_status).to eq("confirmed")
    expect(lonely.reload.match_status).to eq("auto_matched")
  end

  it "never touches a row the chef removed from the list" do
    pm = row(status: "rejected")

    described_class.new(list).call

    expect(performance_items(pm)).to be_empty
  end

  it "leaves a row alone when a chef removed that supplier from it" do
    pm = row
    MatchItemRemoval.create!(organization_id: organization.id, aggregated_list_id: list.id, product_match_id: pm.id,
                             supplier_id: performance.id, cause: "chef_edit")

    described_class.new(list).call

    expect(performance_items(pm)).to be_empty
  end

  it "adds nothing to a row that already has that supplier" do
    pm = row
    sli = create(:supplier_list_item, supplier_list: pfg_list, supplier_product: create(:supplier_product, supplier: performance))
    create(:product_match_item, product_match: pm, supplier_list_item: sli, supplier: performance)

    described_class.new(list).call

    expect(performance_items(pm).size).to eq(1)
  end

  it "leaves it alone when the map points to two products from that supplier" do
    pm = row
    create(:supplier_product, supplier: performance, product: olive_oil)

    result = described_class.new(list).call

    expect(performance_items(pm)).to be_empty
    expect(result.skipped[:ambiguous]).to eq(1)
  end

  it "skips unpriced and discontinued products" do
    pfg_oil.update!(current_price: 0)
    pm = row
    expect(described_class.new(list).call.added).to be_empty

    pfg_oil.update!(current_price: 20, discontinued: true)
    expect(described_class.new(list).call.added).to be_empty
    expect(performance_items(pm)).to be_empty
  end

  it "never adds a product that's already on the list, even on a removed row" do
    row(status: "rejected", supplier_product: pfg_oil, supplier_list: pfg_list)
    pm = row

    described_class.new(list).call

    expect(performance_items(pm)).to be_empty
  end

  it "does nothing for a supplier that isn't connected at this restaurant" do
    list.aggregated_list_mappings.where(supplier_list: pfg_list).destroy_all
    pm = row

    described_class.new(list).call

    expect(performance_items(pm)).to be_empty
  end

  it "reports without writing on a dry run" do
    pm = row

    result = described_class.new(list, dry_run: true).call

    expect(result.added.size).to eq(1)
    expect(performance_items(pm)).to be_empty
  end

  it "runs whenever a supplier's list is synced into the matched list" do
    pm = row

    SyncNewProductsJob.perform_now(list.id)

    expect(performance_items(pm).size).to eq(1)
  end
end
