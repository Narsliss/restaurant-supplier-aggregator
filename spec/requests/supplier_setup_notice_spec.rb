require "rails_helper"

# In the order builder, an owner at a restaurant a picker login couldn't place
# is told once, with a way to fix it. Nothing shows when all is well, and
# chefs never see it.
RSpec.describe "Supplier setup notice in the order builder", type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:alfios) { org.locations.first.tap { |l| l.update!(name: "Alfios") } }
  let!(:noche) { create(:location, user: owner, organization: org, name: "Noche") }
  let(:usfoods) { Supplier.find_by(code: "usfoods") || create(:supplier, name: "US Foods", code: "usfoods") }
  let(:mobile_ua) { { "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" } }
  let!(:usf) do
    create(:supplier_credential, user: owner, supplier: usfoods, organization_id: org.id, location_id: alfios.id, status: "active",
                                 supplier_restaurants: [{ "id" => "80998842", "name" => "ALFIO'S" }, { "id" => "31718356", "name" => "NOCHE PNTO" }])
  end
  let(:noche_list) do
    list = create(:aggregated_list, organization: org, location_id: noche.id)
    create(:product_match, aggregated_list: list, match_status: "confirmed")
    list
  end

  before do
    usf.restaurants.create!(location: alfios, supplier_account_id: "80998842")
    sign_in owner
    post switch_location_path, params: { location_id: noche.id }
  end

  def notice
    Nokogiri::HTML(response.body).at_css("[data-supplier-setup-notice='usfoods']")
  end

  it "tells the owner US Foods isn't set up for Noche yet, with a fix link" do
    get order_builder_aggregated_list_path(noche_list)

    expect(notice.text).to include("US Foods", "isn't set up for Noche yet")
    expect(notice.at_css("a")["href"]).to eq(supplier_credentials_path)
  end

  it "shows on a phone too" do
    get order_builder_aggregated_list_path(noche_list), headers: mobile_ua

    expect(notice).to be_present
  end

  it "stays quiet once Noche is linked" do
    usf.restaurants.create!(location: noche, supplier_account_id: "31718356")

    get order_builder_aggregated_list_path(noche_list)

    expect(notice).to be_nil
  end

  it "stays quiet when the supplier simply doesn't list the restaurant" do
    usf.update!(supplier_restaurants: [{ "id" => "80998842", "name" => "ALFIO'S" }, { "id" => "11806627", "name" => "D'ORO" }])
    usf.restaurants.create!(location: create(:location, organization: org, user: owner, name: "D'oro"), supplier_account_id: "11806627")

    get order_builder_aggregated_list_path(noche_list)

    expect(notice).to be_nil
  end

  it "is never shown to a chef" do
    chef = create(:user, current_organization: org)
    create(:membership, user: chef, organization: org, role: "chef", active: true).membership_locations.create!(location: noche)
    create(:subscription, user: chef, organization_id: org.id)
    create(:supplier_credential, user: chef, supplier: usfoods, organization_id: org.id, location_id: noche.id, status: "active",
                                 supplier_restaurants: [{ "id" => "1" }, { "id" => "2" }])
    sign_in chef
    post switch_location_path, params: { location_id: noche.id }

    get order_builder_aggregated_list_path(noche_list)

    expect(Nokogiri::HTML(response.body).at_css("[data-supplier-setup-notice]")).to be_nil
  end
end
