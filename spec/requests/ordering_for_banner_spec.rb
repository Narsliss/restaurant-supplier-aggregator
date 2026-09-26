require "rails_helper"

# Chefs are often in a hurry, and an owner can order for several restaurants:
# the builder and the cart must say, unmissably, which restaurant the order is
# for. Display only — nothing here changes how orders are placed.
RSpec.describe "Ordering-for banner", type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:alfios) { org.locations.first.tap { |l| l.update!(name: "Alfios", address: "2724 Erie Ave", city: "Cincinnati") } }
  let!(:noche) { create(:location, user: owner, organization: org, name: "Noche") }
  let(:mobile_ua) { { "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" } }
  let(:alfios_list) do
    list = create(:aggregated_list, organization: org, location_id: alfios.id)
    create(:product_match, aggregated_list: list, match_status: "confirmed")
    list
  end

  before { sign_in owner }

  def banner
    Nokogiri::HTML(response.body).at_css("[data-ordering-for-state]")
  end

  describe "order builder" do
    it "names the restaurant the orders are for, with its address" do
      post switch_location_path, params: { location_id: alfios.id }
      get order_builder_aggregated_list_path(alfios_list)

      expect(banner["data-ordering-for-state"]).to eq("ok")
      expect(banner["data-ordering-for"]).to eq(alfios.id.to_s)
      expect(banner.text).to include("You are ordering for", "Alfios", "2724 Erie Ave, Cincinnati")
    end

    it "warns in red when the orders would go to a different restaurant than the list shown" do
      post switch_location_path, params: { location_id: noche.id }
      get order_builder_aggregated_list_path(alfios_list)

      expect(banner["data-ordering-for-state"]).to eq("mismatch")
      expect(banner["class"]).to include("bg-red-600")
      expect(banner.text).to include("Noche", "this is Alfios's list, but these orders will be placed for Noche")
    end

    it "cannot be reached with no restaurant selected (All Locations)" do
      post switch_location_path, params: { location_id: "all" }
      get order_builder_aggregated_list_path(alfios_list)

      expect(response).to be_redirect
    end

    it "would warn in red if it were ever rendered without a restaurant" do
      html = ApplicationController.render(partial: "shared/ordering_for_banner", locals: { location: nil })
      node = Nokogiri::HTML(html).at_css("[data-ordering-for-state]")

      expect(node["data-ordering-for-state"]).to eq("missing")
      expect(node["class"]).to include("bg-red-600")
      expect(node.text).to include("No location selected")
    end

    it "shows the banner on a phone too" do
      post switch_location_path, params: { location_id: alfios.id }
      get order_builder_aggregated_list_path(alfios_list), headers: mobile_ua

      expect(banner["data-ordering-for-state"]).to eq("ok")
      expect(banner.text).to include("Alfios")
    end
  end

  describe "cart / review" do
    let(:batch_id) { SecureRandom.uuid }

    before do
      create(:order, user: owner, organization: org, location: noche, status: "pending", batch_id: batch_id)
      # The review page shows the orders of the selected restaurant.
      post switch_location_path, params: { location_id: noche.id }
    end

    it "names the restaurant the orders in the cart are recorded for" do
      get review_orders_path(batch_id: batch_id)

      expect(banner["data-ordering-for"]).to eq(noche.id.to_s)
      expect(banner.text).to include("You are ordering for", "Noche")
    end

    it "shows it on the phone cart too" do
      get review_orders_path(batch_id: batch_id), headers: mobile_ua

      expect(banner.text).to include("Noche")
    end
  end

  # Only people who can switch restaurants in EnPlace see it — a chef who can
  # only ever order for one restaurant keeps their screen space.
  describe "who sees it" do
    let(:chef) do
      user = create(:user, current_organization: org)
      membership = create(:membership, user: user, organization: org, role: "chef", active: true)
      membership.membership_locations.create!(location: alfios)
      create(:subscription, user: user, organization_id: org.id)
      # A chef with no supplier connection is sent to onboarding first.
      create(:supplier_credential, user: user, organization: org, location: alfios, supplier: create(:supplier))
      user
    end

    it "is not shown to a chef who orders for one restaurant" do
      sign_in chef
      get order_builder_aggregated_list_path(alfios_list)

      expect(response).to have_http_status(:ok)
      expect(banner).to be_nil
    end

    it "is not shown to an owner with a single restaurant" do
      noche.destroy!
      post switch_location_path, params: { location_id: alfios.id }
      get order_builder_aggregated_list_path(alfios_list)

      expect(response).to have_http_status(:ok)
      expect(banner).to be_nil
    end
  end
end
