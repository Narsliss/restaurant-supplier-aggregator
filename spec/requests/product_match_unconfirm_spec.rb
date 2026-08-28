require "rails_helper"

# Confirming was a one-way door. Carmin set a pack weight and came back to a
# line marked "Chef confirmed" they had never signed off on, and nothing in the
# app could take it back — while confirmed lines sink to the bottom of the page,
# away from the review that would have caught it.
RSpec.describe "Undoing a sign-off", type: :request do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:supplier) { create(:supplier, name: "Chef's Warehouse") }
  let(:aggregated_list) { create(:aggregated_list, organization: organization, location_id: location.id) }

  let(:chef) do
    user = create(:user, current_organization: organization)
    m = create(:membership, user: user, organization: organization, role: "chef", active: true)
    m.membership_locations.create!(location: location)
    create(:subscription, user: user, organization_id: organization.id)
    create(:supplier_credential, user: user, organization: organization, location: location,
                                 supplier: supplier, status: "active")
    user
  end

  let(:match) do
    m = create(:product_match, aggregated_list: aggregated_list, canonical_name: "Cookies - Lady Finger")
    list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
    aggregated_list.aggregated_list_mappings.find_or_create_by!(supplier_list: list)
    sli = create(:supplier_list_item, supplier_list: list, name: "Lady Fingers", sku: "SKU-1")
    create(:product_match_item, product_match: m, supplier_list_item: sli, supplier: supplier)
    m
  end

  before { sign_in chef }

  it "returns a confirmed match to the queue" do
    match.confirm!
    expect(match.reload).to be_confirmed

    post unconfirm_aggregated_list_product_match_path(aggregated_list, match)

    expect(match.reload).not_to be_confirmed
    expect(match.match_status).to eq("auto_matched")
    expect(match.reviewed_at).to be_nil
  end

  it "offers the undo in the modal beside the badge" do
    match.confirm!
    get edit_aggregated_list_product_match_path(aggregated_list, match)

    expect(response.body).to include("Chef confirmed")
    expect(response.body).to include(unconfirm_aggregated_list_product_match_path(aggregated_list, match))
  end

  it "does nothing to a match that was never confirmed" do
    expect { post unconfirm_aggregated_list_product_match_path(aggregated_list, match) }
      .not_to change { match.reload.match_status }
  end
end
