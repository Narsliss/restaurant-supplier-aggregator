require "rails_helper"

# The one-time "which of your restaurants is this?" step for an owner's (or
# manager's) multi-restaurant supplier login. Chefs never see it.
RSpec.describe "Matching a supplier login's restaurants", type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:alfios) { org.locations.first.tap { |l| l.update!(name: "Alfios") } }
  let!(:noche) { create(:location, organization: org, user: owner, name: "Noche") }
  let(:supplier) { Supplier.find_by(code: "usfoods") || create(:supplier, name: "US Foods", code: "usfoods") }
  let!(:credential) do
    create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id,
                                 location_id: alfios.id, status: "active")
  end
  let(:restaurants) do
    [{ id: "80998842", name: "ALFIO'S BUON CIBO PNTO — CINCINNATI", meta: { "division_number" => 1103 } },
     { id: "31718356", name: "NOCHE PNTO — COVINGTON", meta: { "division_number" => 1103 } }]
  end

  before do
    allow(Suppliers::RestaurantSwitcher).to receive(:list_restaurants).and_return(restaurants)
    # Don't depend on the seeded US Foods row (a factory-built one has no real scraper class).
    allow_any_instance_of(Supplier).to receive(:scraper_klass).and_return(double(new: double(api_client: double)))
    sign_in owner
    post switch_location_path, params: { location_id: alfios.id }
  end

  it "lists the login's restaurants with a location picker for each" do
    get restaurants_supplier_credential_path(credential)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("NOCHE PNTO", "31718356", "ALFIO&#39;S BUON CIBO PNTO")
    expect(credential.reload.supplier_restaurant_count).to eq(2)
  end

  it "saves the matches and starts syncing each restaurant" do
    expect do
      patch restaurants_supplier_credential_path(credential),
            params: { restaurants: { "80998842" => alfios.id, "31718356" => noche.id } }
    end.to have_enqueued_job(ImportSupplierListsJob).with(credential.id, force: true)

    matches = credential.restaurants.order(:supplier_account_id).pluck(:supplier_account_id, :location_id)
    expect(matches).to eq([["31718356", noche.id], ["80998842", alfios.id]])
    expect(credential.restaurants.find_by(location: noche).account_meta).to eq("division_number" => 1103)
  end

  it "requires the connection's own restaurant to be matched" do
    patch restaurants_supplier_credential_path(credential), params: { restaurants: { "31718356" => noche.id } }

    expect(credential.restaurants).to be_empty
    expect(flash[:alert]).to include("Alfios")
  end

  it "refuses one location for two restaurants" do
    patch restaurants_supplier_credential_path(credential),
          params: { restaurants: { "80998842" => alfios.id, "31718356" => alfios.id } }

    expect(credential.restaurants).to be_empty
  end

  it "can stop switching" do
    credential.restaurants.create!(location: alfios, supplier_account_id: "80998842")

    delete restaurants_supplier_credential_path(credential)

    expect(credential.restaurants.reload).to be_empty
  end

  it "lets the owner use the matched login when ordering for Noche" do
    credential.restaurants.create!(location: alfios, supplier_account_id: "80998842")
    credential.restaurants.create!(location: noche, supplier_account_id: "31718356")
    post switch_location_path, params: { location_id: noche.id }

    get supplier_credentials_path

    links = Nokogiri::HTML(response.body).at_css("[data-restaurant-links]")
    expect(links.text).to include("Orders for", "Alfios", "Noche")
  end

  it "offers nothing to an owner with a single restaurant" do
    noche.destroy!

    get supplier_credentials_path

    expect(response.body).not_to include(restaurants_supplier_credential_path(credential))
  end

  describe "chefs" do
    let(:chef) do
      user = create(:user, current_organization: org)
      m = create(:membership, user: user, organization: org, role: "chef", active: true)
      m.membership_locations.create!(location: alfios)
      create(:subscription, user: user, organization_id: org.id)
      user
    end
    let!(:chef_cred) do
      create(:supplier_credential, user: chef, supplier: supplier, organization_id: org.id,
                                   location_id: alfios.id, status: "active")
    end

    before { sign_in chef }

    it "never reach the matching page" do
      get restaurants_supplier_credential_path(chef_cred)

      expect(response).to redirect_to(supplier_credentials_path)
      expect(Suppliers::RestaurantSwitcher).not_to have_received(:list_restaurants)
    end

    it "see no Restaurants link on their suppliers page" do
      get supplier_credentials_path

      expect(response.body).not_to include(restaurants_supplier_credential_path(chef_cred))
    end
  end
end
