require 'rails_helper'

# supplier_requirements has no organization: a location: nil row is the
# EnPlace-wide default shared by EVERY restaurant. Until Oct 2026 any member
# saving the settings page's "Default" column rewrote it for everyone and
# deleted every restaurant's per-location minimums for that supplier.
RSpec.describe 'Per-location supplier minimums', type: :request do
  let(:chef) { create(:user, :fully_onboarded) }
  let(:org) { chef.current_organization }
  let(:location) { org.locations.first }
  let(:supplier) { create(:supplier, name: "Chef's Warehouse") }

  let(:other_owner) { create(:user, :fully_onboarded) }
  let(:other_location) { other_owner.current_organization.locations.first }

  let!(:shared_default) do
    SupplierRequirement.create!(supplier: supplier, location: nil, requirement_type: 'order_minimum',
                                numeric_value: 400, is_blocking: true, active: true, error_message: 'min')
  end
  let!(:other_restaurants_minimum) do
    SupplierRequirement.create!(supplier: supplier, location: other_location, requirement_type: 'order_minimum',
                                numeric_value: 250, is_blocking: true, active: true, error_message: 'min')
  end

  def save_minimum(location_id:, value:)
    post update_requirement_organization_path(format: :json),
         params: { supplier_id: supplier.id, requirement_type: 'order_minimum', location_id: location_id, value: value },
         as: :json
  end

  before { sign_in chef }

  it "lets a chef set their own restaurant's minimum" do
    save_minimum(location_id: location.id, value: 300)

    expect(response).to have_http_status(:ok)
    expect(supplier.order_minimum(location)).to eq(300)
  end

  it 'refuses to change the EnPlace-wide default for a non-admin' do
    save_minimum(location_id: '', value: 100)

    expect(response).to have_http_status(:forbidden)
    expect(shared_default.reload.numeric_value).to eq(400)
  end

  it "never deletes another restaurant's minimum" do
    save_minimum(location_id: '', value: 100)
    save_minimum(location_id: location.id, value: 300)

    expect(other_restaurants_minimum.reload.numeric_value).to eq(250)
    expect(supplier.order_minimum(other_location)).to eq(250)
  end

  it "can't touch a location in another organization" do
    save_minimum(location_id: other_location.id, value: 1)

    expect(response.status).not_to eq(200)
    expect(other_restaurants_minimum.reload.numeric_value).to eq(250)
  end

  it 'clearing a box goes back to the EnPlace default' do
    save_minimum(location_id: location.id, value: 300)
    save_minimum(location_id: location.id, value: 0)

    expect(supplier.order_minimum(location)).to eq(400)
  end

  context 'as a super admin' do
    let(:admin) { create(:user, :super_admin, :fully_onboarded) }

    before { sign_in admin }

    it "can change the EnPlace default, and that leaves every restaurant's own minimum alone" do
      post update_requirement_organization_path(format: :json),
           params: { supplier_id: supplier.id, requirement_type: 'order_minimum', location_id: '', value: 350 },
           as: :json

      expect(response).to have_http_status(:ok)
      expect(shared_default.reload.numeric_value).to eq(350)
      expect(other_restaurants_minimum.reload.numeric_value).to eq(250)
    end
  end

  it 'shows every restaurant an editable box with the default as the placeholder — nothing locked' do
    create(:supplier_credential, user: chef, supplier: supplier, status: 'active')

    get organization_path(org)

    body = response.body
    expect(body).to include('EnPlace default', '$400.00')
    expect(body).to include(%(data-location-id="#{location.id}"))
    expect(body).to include('placeholder="400.00"')
    expect(body).not_to include('Locked — using default')
  end
end
