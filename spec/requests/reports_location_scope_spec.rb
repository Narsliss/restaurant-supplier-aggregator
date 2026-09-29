require "rails_helper"

# Carmin (Sep 29 2026): Reports showed only Alfio's first restaurant — Noche
# read $0 despite 17 orders. Reports followed the navbar location switcher
# (built for ordering), and while impersonating the switcher itself was
# refused by the read-only guard, so it could never leave that restaurant.
RSpec.describe "Reports across restaurants", type: :request do
  let(:organization) { create(:organization) }
  let(:alfios) { create(:location, organization: organization, name: "alfios") }
  let(:noche) { create(:location, organization: organization, name: "Noche") }
  let(:doro) { create(:location, organization: organization, name: "D'oro") }
  let(:supplier) { create(:supplier) }

  def member(role, locations)
    user = create(:user, current_organization: organization)
    membership = create(:membership, user: user, organization: organization, role: role, active: true)
    locations.each { |loc| membership.membership_locations.create!(location: loc) }
    create(:subscription, user: user, organization_id: organization.id)
    create(:supplier_credential, user: user, organization: organization, location: locations.first,
                                 supplier: supplier, status: "active")
    user
  end

  let!(:owner) { member("owner", [alfios, noche, doro]) }
  let!(:teammate) { create(:membership, user: create(:user), organization: organization, role: "chef", active: true) }

  def submitted_order(location, total)
    order = create(:order, user: owner, organization: organization, location: location,
                           supplier: supplier, status: "submitted", submitted_at: 1.day.ago)
    order.update_columns(total_amount: total)
    order
  end

  def spent_by_restaurant
    controller.instance_variable_get(:@by_restaurant).to_h { |r| [r[:location].name, r[:total_spent].to_f] }
  end

  before do
    submitted_order(alfios, 700)
    submitted_order(noche, 500)
  end

  it "counts every restaurant whichever one the navbar has selected" do
    sign_in owner
    post switch_location_path, params: { location_id: alfios.id }, as: :json

    get reports_path

    expect(spent_by_restaurant).to include("alfios" => 700.0, "Noche" => 500.0, "D'oro" => 0.0)
  end

  it "still narrows to one restaurant with the report's own filter" do
    sign_in owner

    get reports_path(location_id: noche.id)

    expect(controller.instance_variable_get(:@summary)).to be_present
    expect(spent_by_restaurant["Noche"]).to eq(500.0)
    expect(spent_by_restaurant["alfios"]).to eq(0.0)
  end

  it "keeps a manager to the restaurants they are assigned" do
    manager = member("manager", [noche])
    sign_in manager
    post switch_location_path, params: { location_id: noche.id }, as: :json

    get reports_path

    expect(spent_by_restaurant).to eq("Noche" => 500.0)
  end

  # Carmin (Sep 29 2026): savings are measured against the most expensive
  # comparable supplier (the careless-order view). The label says so, because
  # a line can "save" more than was spent on it (All Trumps flour: $167 paid,
  # $412 at the priciest supplier).
  it "labels savings as measured against the priciest option" do
    sign_in owner

    get reports_path

    expect(response.body).to include("Saved vs. Priciest")
    expect(response.body).not_to include(">Total Savings<")
  end

  describe "while impersonating" do
    let(:super_admin) do
      User.where(role: "super_admin").destroy_all
      create(:user, :super_admin)
    end

    before do
      sign_in super_admin
      post "/admin/users/#{owner.id}/impersonate"
    end

    it "lets the location switcher change restaurants" do
      post switch_location_path, params: { location_id: noche.id }, as: :json

      expect(response).to have_http_status(:ok)
      expect(session[:current_location_id]).to eq(noche.id)
    end

    it "still blocks real writes" do
      post locations_path, params: { location: { name: "Sneaky" } }

      expect(response).to be_redirect
      expect(flash[:alert]).to match(/Read-only mode/)
      expect(Location.where(name: "Sneaky")).to be_empty
    end
  end
end
