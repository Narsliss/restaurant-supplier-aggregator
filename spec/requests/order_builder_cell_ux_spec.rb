require "rails_helper"

# Order builder supplier cells (chef feedback 2026-08-25):
# - BEST is carried by the pill alone — no green border, no green fill
# - the orange ring is the only outline, and marks the supplier that will be ordered
# - a cell's background fills only once the item is actually ordered
#
# Each product row is rendered twice per page (desktop card + in-page mobile
# card), so the assertions count both copies.
RSpec.describe "Order builder cell UX", type: :request do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:chef) do
    user = create(:user, current_organization: organization)
    membership = create(:membership, user: user, organization: organization, role: "chef", active: true)
    membership.membership_locations.create!(location: location)
    user
  end
  let(:cheap_supplier) { create(:supplier, name: "Premiere Produce One") }
  let(:pricey_supplier) { create(:supplier, name: "What Chefs Want") }
  let!(:subscription) { create(:subscription, user: chef, organization_id: organization.id) }

  let!(:aggregated_list) do
    list = create(:aggregated_list, organization: organization, location_id: location.id)
    match = create(:product_match, aggregated_list: list, canonical_name: "Chicken Breast")

    [[cheap_supplier, 40.00], [pricey_supplier, 68.90]].each do |supplier, price|
      create(:supplier_credential, user: chef, organization: organization, location: location,
                                   supplier: supplier, status: "active")
      supplier_list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
      list.aggregated_list_mappings.find_or_create_by!(supplier_list: supplier_list)
      sli = create(:supplier_list_item, supplier_list: supplier_list, name: "Chicken Breast", price: price,
                                        supplier_product: create(:supplier_product, supplier: supplier,
                                                                                    current_price: price, in_stock: true))
      create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: supplier)
    end
    list
  end

  before do
    sign_in chef
    get order_builder_aggregated_list_path(aggregated_list)
  end

  # Every supplier cell on the page — the desktop card and the in-page mobile
  # card each render one per supplier.
  def supplier_cells
    Nokogiri::HTML(response.body).css('[data-order-builder-target="supplierCell"]')
  end

  def cells_with(css_class)
    supplier_cells.select { |cell| cell["class"].to_s.split(/\s+/).include?(css_class) }
  end

  it "renders successfully with a BEST pill on the cheapest cell" do
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("data-best-badge")
    expect(response.body).to include(">BEST</span>")
  end

  it "gives the BEST cell no green border and no green fill" do
    green = %w[border-green-500 border-green-200 bg-green-50 bg-green-100]
    expect(supplier_cells).to be_present
    supplier_cells.each do |cell|
      expect(cell["class"].to_s.split(/\s+/) & green).to be_empty
    end
  end

  it "outlines only the selected supplier cell" do
    # One ring per match per rendering (desktop card + in-page mobile card).
    expect(cells_with("ring-brand-orange").size).to eq(2)
  end

  it "leaves cell backgrounds unfilled while nothing is ordered" do
    expect(cells_with("bg-brand-orange-50")).to be_empty
    expect(cells_with("bg-gray-50").size).to eq(supplier_cells.size)
  end

  it "fills the selected cell's background once the item is ordered" do
    put current_order_path, params: {
      aggregated_list_id: aggregated_list.id,
      state: { aggregated_list.product_matches.first.id.to_s => {
        supplierId: cheap_supplier.id.to_s, qty: 2, uom: "CS"
      } },
      delivery_date: Date.tomorrow.iso8601
    }, as: :json

    get order_builder_aggregated_list_path(aggregated_list)
    filled = cells_with("bg-brand-orange-50")
    expect(filled.size).to eq(2)
    expect(filled.map { |cell| cell["data-supplier-id-value"] }.uniq).to eq([cheap_supplier.id.to_s])
  end
end
