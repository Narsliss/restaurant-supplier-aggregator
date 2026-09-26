require "rails_helper"

# A product the supplier discontinued stays in the chef's matched row (their
# match is never deleted), but it has no price and says why — before Sep 25
# 2026 US Foods' error "0" was stored as a price and shown as $0.00.
RSpec.describe "Order builder: discontinued products", type: :request do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:chef) do
    user = create(:user, current_organization: organization)
    membership = create(:membership, user: user, organization: organization, role: "chef", active: true)
    membership.membership_locations.create!(location: location)
    user
  end
  let(:mobile_ua) { { "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" } }
  let(:usf) { create(:supplier, name: "Disc US Foods") }
  let(:cw) { create(:supplier, name: "Disc Chefs Warehouse") }
  let!(:subscription) { create(:subscription, user: chef, organization_id: organization.id) }

  let!(:aggregated_list) do
    list = create(:aggregated_list, organization: organization, location_id: location.id)
    match = create(:product_match, aggregated_list: list, canonical_name: "Heirloom Tomatoes", match_status: "confirmed")
    [[usf, nil, true], [cw, 42.0, false]].each do |supplier, price, gone|
      create(:supplier_credential, user: chef, organization: organization, location: location, supplier: supplier)
      supplier_list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
      list.aggregated_list_mappings.find_or_create_by!(supplier_list: supplier_list)
      sp = create(:supplier_product, supplier: supplier, current_price: price, discontinued: gone)
      sli = create(:supplier_list_item, supplier_list: supplier_list, name: "Heirloom Tomatoes",
                                        price: price, supplier_product: sp)
      create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: supplier)
    end
    list
  end

  before { sign_in chef }

  it "labels the discontinued supplier's cell instead of offering a price" do
    get order_builder_aggregated_list_path(aggregated_list)

    expect(response.body).to include(">Discontinued</div>")
    orderable = Nokogiri::HTML(response.body).css('[data-order-builder-target="supplierCell"]')
                        .map { |cell| cell["data-supplier-id-value"] }.uniq
    expect(orderable).to eq([cw.id.to_s])
  end

  it "does the same on a phone" do
    get order_builder_aggregated_list_path(aggregated_list), headers: mobile_ua

    expect(response.body).to include("Discontinued")
  end
end
