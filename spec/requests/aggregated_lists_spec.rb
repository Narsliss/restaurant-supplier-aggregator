require 'rails_helper'

RSpec.describe 'AggregatedLists', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:location) { org.locations.first }

  before { sign_in owner }

  describe 'GET /aggregated_lists/:id (show)' do
    let(:aggregated_list) do
      # The Location.after_create_commit callback creates a matched list for
      # the default location during :fully_onboarded setup — reuse it.
      AggregatedList.find_by!(organization: org, location_id: location.id, list_type: 'matched')
    end

    # Regression: chef opens a matched list and sees no column for a supplier
    # they have credentials for, just because no SupplierList has been scraped
    # into the agg yet (or it landed at a sibling location due to a dedup quirk).
    # The fix expands @suppliers to include every supplier credentialed at the
    # list's location, so the column always renders and the chef can match
    # items into it.
    it 'shows a column for a credentialed supplier even with no supplier_list in the agg' do
      supplier = create(:supplier, name: 'AcmeFoodsUniqueName')
      create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id, location_id: location.id)

      get aggregated_list_path(aggregated_list)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('AcmeFoodsUniqueName')
    end

    it 'still shows suppliers connected via a supplier_list at the location' do
      # show#action has a safety net that auto-links any supplier_list at the
      # list's location, so a bare SupplierList at this location is enough to
      # exercise the supplier_list-derived branch of @suppliers.
      supplier = create(:supplier, name: 'ListOnlySupplierUniqueName')
      SupplierList.create!(
        supplier: supplier,
        organization_id: org.id,
        location_id: location.id,
        name: 'Order Guide',
        remote_list_id: 'order-guide'
      )

      get aggregated_list_path(aggregated_list)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('ListOnlySupplierUniqueName')
    end
  end
end
