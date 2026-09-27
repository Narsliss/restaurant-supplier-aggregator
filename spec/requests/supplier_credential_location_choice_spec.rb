require "rails_helper"

# An owner with several restaurants says which restaurant a new supplier login
# is for (Performance: a separate login per restaurant). Each restaurant can
# have only one connection per supplier, only the owner's own restaurants can
# be chosen, and editing a connection never moves it to another restaurant.
RSpec.describe "Choosing the restaurant for a supplier connection", type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:alfios) { org.locations.first.tap { |l| l.update!(name: "Alfios") } }
  let!(:noche) { create(:location, organization: org, user: owner, name: "Noche") }
  let!(:doro) { create(:location, organization: org, user: owner, name: "D'oro") }
  let(:performance) { Supplier.find_by(code: "performance") || create(:supplier, name: "Performance", code: "performance") }

  before do
    allow(ValidateCredentialsJob).to receive(:perform_later)
    sign_in owner
    post switch_location_path, params: { location_id: alfios.id }
  end

  def connect(location)
    post supplier_credentials_path, params: {
      supplier_credential: { supplier_id: performance.id, username: "doro@example.com", password: "x", location_id: location.id }
    }
  end

  it "asks which restaurant the login is for" do
    get new_supplier_credential_path(supplier_id: performance.id)

    expect(response.body).to include("Which restaurant is this login for?")
    expect(response.body).to include(">D&#39;oro</option>", ">Noche</option>", ">Alfios</option>")
  end

  it "connects the login to the chosen restaurant, not the one selected at the top" do
    expect { connect(doro) }.to change(SupplierCredential, :count).by(1)

    expect(SupplierCredential.last.location).to eq(doro)
  end

  it "tells the form which restaurants already have that supplier" do
    create(:supplier_credential, user: owner, supplier: performance, organization_id: org.id, location: noche)

    get new_supplier_credential_path(supplier_id: performance.id)

    taken = JSON.parse(Nokogiri::HTML(response.body).at("form[data-controller='credential-form']")["data-credential-form-taken-locations-value"])
    expect(taken[performance.id.to_s]).to eq([noche.id])
  end

  it "refuses a second connection for a restaurant that already has that supplier" do
    create(:supplier_credential, user: owner, supplier: performance, organization_id: org.id, location: doro)

    expect { connect(doro) }.not_to change(SupplierCredential, :count)
  end

  it "keeps offering the supplier until every restaurant has it" do
    [alfios, noche].each do |loc|
      create(:supplier_credential, user: owner, supplier: performance, organization_id: org.id, location: loc)
    end
    get new_supplier_credential_path
    expect(response.body).to include(">#{performance.name}</option>")

    create(:supplier_credential, user: owner, supplier: performance, organization_id: org.id, location: doro)
    get new_supplier_credential_path
    expect(response.body).not_to include(">#{performance.name}</option>")
  end

  it "refuses a restaurant from another organization" do
    elsewhere = create(:location, organization: create(:organization))

    expect { connect(elsewhere) }.not_to change(SupplierCredential, :count)
  end

  it "never moves a connection when it is edited" do
    cred = create(:supplier_credential, user: owner, supplier: performance, organization_id: org.id, location: alfios)

    patch supplier_credential_path(cred), params: { supplier_credential: { location_id: doro.id, username: cred.username } }

    expect(cred.reload.location).to eq(alfios)
  end

  it "keeps a one-restaurant owner's form as it was" do
    [noche, doro].each(&:destroy!)

    get new_supplier_credential_path(supplier_id: performance.id)

    expect(response.body).not_to include("Which restaurant is this login for?")
  end

  describe "a chef" do
    let(:chef) do
      user = create(:user, current_organization: org)
      create(:membership, user: user, organization: org, role: "chef", active: true)
        .membership_locations.create!(location: noche)
      create(:subscription, user: user, organization_id: org.id)
      user
    end

    before do
      sign_in chef
      post switch_location_path, params: { location_id: noche.id }
    end

    it "always connects for their own restaurant, whatever location is posted" do
      post supplier_credentials_path, params: {
        supplier_credential: { supplier_id: performance.id, username: "nate@example.com", password: "x", location_id: doro.id }
      }

      expect(chef.supplier_credentials.last&.location).to eq(noche)
    end
  end
end
