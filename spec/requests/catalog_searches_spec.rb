require 'rails_helper'

RSpec.describe 'Catalog search (quick order)', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:location) { org.locations.first }
  let(:matched_list) do
    AggregatedList.find_by(organization: org, location_id: location.id, list_type: %w[master matched])
  end

  before { sign_in owner }

  def search(query)
    get catalog_search_path(q: query, format: :json)
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body)
  end

  def connect!(supplier)
    create(:supplier_credential, user: owner, supplier: supplier,
                                 organization_id: org.id, location_id: location.id, status: 'active')
  end

  describe 'Issue 1 — only suppliers the searcher is connected to' do
    let(:connected_supplier) { create(:supplier, name: 'Connected Co') }
    let(:unconnected_supplier) { create(:supplier, name: 'Unconnected Co') }

    before do
      connect!(connected_supplier)
      create(:supplier_product, supplier: connected_supplier, supplier_name: 'Widget Connected', current_price: 10)
      create(:supplier_product, supplier: unconnected_supplier, supplier_name: 'Widget Orphan', current_price: 10)
    end

    it 'includes products from suppliers the searcher has an active login for' do
      names = search('widget').map { |r| r['name'] }
      expect(names).to include('Widget Connected')
    end

    it 'excludes products from suppliers the searcher is NOT connected to' do
      names = search('widget').map { |r| r['name'] }
      expect(names).not_to include('Widget Orphan')
    end

    # Regression: previously a supplier merely present on the matched list (via an
    # imported order guide) leaked into results even with no active credential.
    it 'excludes a supplier that is on the matched list but has no active login' do
      supplier_list = SupplierList.create!(
        supplier: unconnected_supplier, organization_id: org.id, location_id: location.id,
        name: 'Order Guide', remote_list_id: 'order-guide'
      )
      matched_list.aggregated_list_mappings.find_or_create_by!(supplier_list: supplier_list)

      names = search('widget').map { |r| r['name'] }
      expect(names).not_to include('Widget Orphan')
    end

    it 'excludes suppliers whose credential is not active' do
      inactive_supplier = create(:supplier, name: 'Expired Co')
      create(:supplier_credential, user: owner, supplier: inactive_supplier,
                                   organization_id: org.id, location_id: location.id, status: 'expired')
      create(:supplier_product, supplier: inactive_supplier, supplier_name: 'Widget Expired', current_price: 10)

      names = search('widget').map { |r| r['name'] }
      expect(names).not_to include('Widget Expired')
    end
  end

  describe 'Issue 2 — no 20-item cap' do
    let(:connected_supplier) { create(:supplier, name: 'Bulk Co') }

    before do
      connect!(connected_supplier)
      25.times { |i| create(:supplier_product, supplier: connected_supplier, supplier_name: format('Gadget %02d', i), current_price: 10) }
    end

    it 'returns more than 20 matching products (cap raised from 20)' do
      results = search('gadget')
      expect(results.size).to eq(25)
    end
  end
end
