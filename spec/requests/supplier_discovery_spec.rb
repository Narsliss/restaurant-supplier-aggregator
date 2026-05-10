require 'rails_helper'

RSpec.describe 'EmailSuppliers', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }

  before { sign_in owner }

  describe 'GET /email_suppliers/new' do
    it 'returns 200' do
      get new_email_supplier_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /email_suppliers' do
    it 'creates a new email supplier' do
      expect {
        post email_suppliers_path, params: {
          supplier: {
            name: 'Blue Ribbon',
            contact_email: 'orders@blue-ribbon.example',
            auth_type: 'email'
          }
        }
      }.to change(Supplier, :count).by(1)
      created = Supplier.last
      expect(created.email_supplier?).to be true
      expect(created.organization).to eq(org)
    end
  end

  describe 'auth gate' do
    it 'redirects unauthenticated to sign in' do
      sign_out owner
      get new_email_supplier_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end

RSpec.describe 'AggregatedLists', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:location) { org.locations.first }

  before { sign_in owner }

  describe 'GET /aggregated_lists' do
    it 'returns 200' do
      get aggregated_lists_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /aggregated_lists' do
    it 'creates an aggregated list' do
      expect {
        post aggregated_lists_path, params: {
          aggregated_list: { name: 'Master mise', location_id: location.id }
        }
      }.to change(AggregatedList, :count).by(1)
    end
  end

  describe 'GET /aggregated_lists/:id/order_builder' do
    let(:matched_list) do
      AggregatedList.create!(
        organization: org,
        location_id: location.id,
        created_by: owner,
        name: 'Builder list',
        list_type: 'matched',
        match_status: 'matched'
      )
    end

    # Regression: chefs typing in the search bar and pressing Enter were jumping
    # to the verify-order page because the search input lives inside the order
    # form. The order-builder Stimulus controller now swallows Enter on inputs;
    # the form must carry the data-action attribute that wires it up.
    it 'wires the form to swallow Enter so accidental submits cannot escape' do
      get order_builder_aggregated_list_path(matched_list)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="order-form"')
      # form_with HTML-escapes data attribute values, so the Stimulus arrow
      # appears as `&gt;` in the source. The browser unescapes it at parse time.
      expect(response.body).to match(/<form[^>]*id="order-form"[^>]*data-action="keydown-&gt;order-builder#preventEnterSubmit"/)
    end
  end
end

RSpec.describe 'CatalogSearches', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }

  before { sign_in owner }

  describe 'GET /catalog_search' do
    it 'returns 200 (without query)' do
      get catalog_search_path
      expect(response).to have_http_status(:ok).or be_redirect
    end
  end
end

RSpec.describe 'PriceComparisons', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:location) { org.locations.first }
  let!(:order_list) { OrderList.create!(user: owner, organization: org, location: location, name: 'Compare') }

  before { sign_in owner }

  describe 'GET /price_comparisons/:id' do
    it 'returns 200 for a list the user can access' do
      get price_comparison_path(order_list)
      expect(response).to have_http_status(:ok)
    end
  end
end
