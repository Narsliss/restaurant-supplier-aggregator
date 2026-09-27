require "rails_helper"

# An owner with several restaurants: one Suppliers page for all of them. Picker
# logins show the restaurants they're linked to (automatically), a one-click
# fix for anything that couldn't be placed, and a quiet note for restaurants
# the supplier doesn't list. Performance: one card, a login per restaurant.
RSpec.describe "Owner suppliers page", type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:alfios) { org.locations.first.tap { |l| l.update!(name: "Alfios") } }
  let!(:noche) { create(:location, organization: org, user: owner, name: "Noche") }
  let!(:doro) { create(:location, organization: org, user: owner, name: "D'oro") }
  let(:usfoods) { Supplier.find_by(code: "usfoods") || create(:supplier, name: "US Foods", code: "usfoods") }
  let(:performance) { Supplier.find_by(code: "performance") || create(:supplier, name: "Performance", code: "performance") }
  let!(:usf) do
    create(:supplier_credential, user: owner, supplier: usfoods, organization_id: org.id, location_id: alfios.id, status: "active",
                                 supplier_restaurants: [{ "id" => "80998842", "name" => "ALFIO'S BUON CIBO PNTO" },
                                                        { "id" => "31718356", "name" => "NOCHE PNTO", "street" => "701 MADISON AVE" }])
  end

  before do
    allow(ImportSupplierListsJob).to receive(:perform_later)
    sign_in owner
    post switch_location_path, params: { location_id: doro.id }
    usf.restaurants.create!(location: alfios, supplier_account_id: "80998842")
  end

  def page
    get supplier_credentials_path
    Nokogiri::HTML(response.body)
  end

  it "shows every login whatever restaurant is selected at the top" do
    expect(page.text).to include(usfoods.name)
  end

  it "shows linked restaurants as chips and a one-click fix for the unplaced one" do
    links = page.at_css("[data-restaurant-links]")

    expect(links.text).to include("Orders for", "Alfios")
    fix = links.at_css("[data-unplaced-restaurant='31718356']")
    expect(fix.text).to include("NOCHE PNTO", "701 MADISON AVE")
    expect(fix.css("option").map(&:text)).to include("Noche", "D'oro")
    expect(fix.css("option").map(&:text)).not_to include("Alfios")
  end

  it "links the restaurant in one click" do
    patch link_restaurant_supplier_credential_path(usf), params: { supplier_account_id: "31718356", location_id: noche.id }

    expect(usf.restaurants.reload.pluck(:supplier_account_id, :location_id)).to include(["31718356", noche.id])
    expect(ImportSupplierListsJob).to have_received(:perform_later).with(usf.id, force: true)
    expect(page.at_css("[data-unplaced-restaurant]")).to be_nil
  end

  it "notes quietly which restaurants the supplier doesn't list, once everything is placed" do
    usf.restaurants.create!(location: noche, supplier_account_id: "31718356")

    expect(page.at_css("[data-restaurant-links]").text).to include("doesn't list D'oro on this login")
  end

  it "refuses a restaurant from another organization or one not on the login" do
    elsewhere = create(:location, organization: create(:organization))
    patch link_restaurant_supplier_credential_path(usf), params: { supplier_account_id: "31718356", location_id: elsewhere.id }
    patch link_restaurant_supplier_credential_path(usf), params: { supplier_account_id: "99999999", location_id: noche.id }

    expect(usf.restaurants.reload.count).to eq(1)
  end

  it "requires the login's own restaurant to be linked first" do
    usf.restaurants.destroy_all

    patch link_restaurant_supplier_credential_path(usf), params: { supplier_account_id: "31718356", location_id: noche.id }

    expect(usf.restaurants.reload).to be_empty
    expect(flash[:alert]).to include("own restaurant first")
  end

  describe "Performance, a login per restaurant" do
    let!(:alfios_login) do
      create(:supplier_credential, user: owner, supplier: performance, organization_id: org.id, location_id: alfios.id, status: "active")
    end

    it "shows one card with a slot per restaurant and an add link for the empty ones" do
      card = page.at_css("[data-login-per-restaurant='performance']")

      expect(card.text).to include("A login per restaurant", "Alfios", "Noche", "D'oro", "No login yet")
      add = card.css("a").map { |a| a["href"] }
      expect(add).to include(new_supplier_credential_path(supplier_id: performance.id, location_id: noche.id))
    end
  end

  describe "connecting a picker supplier twice" do
    it "is refused, and US Foods isn't offered again" do
      get new_supplier_credential_path
      expect(response.body).not_to include(">#{usfoods.name}</option>")

      expect do
        post supplier_credentials_path, params: { supplier_credential: { supplier_id: usfoods.id, username: "x", password: "x", location_id: noche.id } }
      end.not_to change(SupplierCredential, :count)
      expect(response.body).to include("already connected")
    end
  end

  describe "a chef" do
    let(:chef) do
      user = create(:user, current_organization: org)
      create(:membership, user: user, organization: org, role: "chef", active: true).membership_locations.create!(location: noche)
      create(:subscription, user: user, organization_id: org.id)
      user
    end

    it "sees their page exactly as before: no chips, no fixes, no grouped card" do
      create(:supplier_credential, user: chef, supplier: usfoods, organization_id: org.id, location_id: noche.id, status: "active",
                                   supplier_restaurants: [{ "id" => "1" }, { "id" => "2" }])
      sign_in chef
      post switch_location_path, params: { location_id: noche.id }

      doc = page
      expect(doc.at_css("[data-restaurant-links]")).to be_nil
      expect(doc.at_css("[data-login-per-restaurant]")).to be_nil
      expect(doc.text).to include(usfoods.name)
    end
  end
end
