require "rails_helper"

# ORDERING SAFETY — a matched list row can carry a supplier this chef has no
# login for (another user's guide mapped to the same location). Its column is
# hidden, but it used to still win "cheapest", so the builder pre-selected
# nothing sensible and the order service could route the line there, where
# placement can only fail. The default must be the cheapest supplier the chef
# can actually order from.
RSpec.describe "Order builder default supplier", type: :request do
  let(:mobile_ua) { { "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" } }

  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:chef) do
    user = create(:user, current_organization: organization)
    membership = create(:membership, user: user, organization: organization, role: "chef", active: true)
    membership.membership_locations.create!(location: location)
    user
  end
  let(:colleague) { create(:user, current_organization: organization) }
  # Alphabetical display order puts Alpha first, so "first visible cell" and
  # "cheapest orderable" differ — the test can tell them apart.
  let(:alpha) { create(:supplier, name: "Alpha Produce") }
  let(:bravo) { create(:supplier, name: "Bravo Foods") }
  let(:charlie) { create(:supplier, name: "Charlie Provisions") }
  let!(:subscription) { create(:subscription, user: chef, organization_id: organization.id) }

  let!(:aggregated_list) do
    list = create(:aggregated_list, organization: organization, location_id: location.id)
    match = create(:product_match, aggregated_list: list, canonical_name: "Chicken Breast")

    [[alpha, 50.00, chef], [bravo, 40.00, chef], [charlie, 30.00, colleague]].each do |supplier, price, owner|
      create(:supplier_credential, user: owner, organization: organization, location: location,
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
  let(:match) { aggregated_list.product_matches.first }

  before { sign_in chef }

  def doc
    Nokogiri::HTML(response.body)
  end

  it "is still the market-wide cheapest when nobody asks for a narrower set" do
    expect(match.cheapest_supplier[:supplier]).to eq(charlie)
    expect(match.cheapest_supplier(among: [alpha.id, bravo.id])[:supplier]).to eq(bravo)
    expect(match.cheapest_supplier(among: [])).to be_nil
  end

  it "pre-selects the cheapest supplier the chef can order from on desktop" do
    get order_builder_aggregated_list_path(aggregated_list)

    cells = doc.css('[data-order-builder-target="supplierCell"]')
    expect(cells.map { |c| c["data-supplier-id-value"] }.uniq).to contain_exactly(alpha.id.to_s, bravo.id.to_s)

    ringed = cells.select { |c| c["class"].to_s.split(/\s+/).include?("ring-brand-orange") }
    expect(ringed.map { |c| c["data-supplier-id-value"] }.uniq).to eq([bravo.id.to_s])
  end

  it "points the mobile builder's default at the same orderable supplier" do
    get order_builder_aggregated_list_path(aggregated_list), headers: mobile_ua

    card = doc.at_css(%([data-mobile-order-builder-target="card"][data-match-id="#{match.id}"]))
    expect(card["data-cheapest-supplier-id"]).to eq(bravo.id.to_s)
  end

  it "routes a line submitted without a supplier to that same supplier" do
    post create_from_aggregated_list_orders_path, params: {
      aggregated_list_id: aggregated_list.id,
      quantities: { match.id.to_s => "2" },
      delivery_date: Date.tomorrow.iso8601
    }

    expect(Order.where(user: chef).pluck(:supplier_id)).to eq([bravo.id])
  end
end
