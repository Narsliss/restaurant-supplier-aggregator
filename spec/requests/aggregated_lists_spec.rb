require 'rails_helper'

RSpec.describe 'AggregatedLists', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:location) { org.locations.first }

  before { sign_in owner }

  describe 'cleanup: scan / merge / dismiss / purge' do
    let(:aggregated_list) do
      AggregatedList.find_by!(organization: org, location_id: location.id, list_type: 'matched')
    end
    let(:supplier) { create(:supplier) }
    let(:supplier_list) { create(:supplier_list, supplier: supplier, organization: org, location: location) }
    let(:spine) { create(:product) }

    def machine_line(sku)
      sp = create(:supplier_product, supplier: supplier, supplier_sku: sku, product: spine)
      sli = create(:supplier_list_item, supplier_list: supplier_list, sku: sku, supplier_product: sp)
      pm = create(:product_match, aggregated_list: aggregated_list, match_status: 'auto_matched')
      create(:product_match_item, product_match: pm, supplier_list_item: sli)
      pm
    end

    it 'scan flags duplicates and the show page renders the cleanup panel' do
      machine_line('A1')
      dup = machine_line('A1B')

      post scan_duplicates_aggregated_list_path(aggregated_list)
      expect(response).to redirect_to(aggregated_list_path(aggregated_list, anchor: 'cleanup'))
      expect(dup.reload.possible_duplicate_of_id).to be_present

      get aggregated_list_path(aggregated_list)
      expect(response.body).to include('List cleanup')
      expect(response.body).to include('Keep separate')
    end

    it 'merge collapses the flagged line into its keeper' do
      keeper = machine_line('A1')
      dup = machine_line('A1B')
      post scan_duplicates_aggregated_list_path(aggregated_list)

      expect {
        post merge_duplicate_aggregated_list_path(aggregated_list, match_id: dup.id)
      }.to change { aggregated_list.product_matches.count }.by(-1)
      expect(ProductMatch.exists?(keeper.id)).to be(true)
    end

    it 'bulk merge collapses exact duplicates in one request' do
      machine_line('A1')
      dup = machine_line('A1B')
      post scan_duplicates_aggregated_list_path(aggregated_list)

      expect {
        post bulk_merge_duplicates_aggregated_list_path(aggregated_list)
      }.to change { aggregated_list.product_matches.count }.by(-1)
      expect(ProductMatch.exists?(dup.id)).to be(false)
      expect(flash[:notice]).to include('Merged 1 exact duplicate')
    end

    it 'purge removes only empty machine lines' do
      create(:product_match, aggregated_list: aggregated_list, match_status: 'rejected')
      chef_line = create(:product_match, aggregated_list: aggregated_list, match_status: 'manual')

      post purge_empty_matches_aggregated_list_path(aggregated_list)

      expect(ProductMatch.exists?(chef_line.id)).to be(true)
      expect(aggregated_list.product_matches.where(match_status: 'rejected')).to be_empty
    end
  end

  describe 'GET /aggregated_lists/:id (show)' do
    let(:aggregated_list) do
      # The Location.after_create_commit callback creates a matched list for
      # the default location during :fully_onboarded setup — reuse it.
      AggregatedList.find_by!(organization: org, location_id: location.id, list_type: 'matched')
    end

    # Regression (Carmin, sandbox onboarding test): a single-supplier line
    # whose equivalent WAS found at a non-connected supplier (teaser) showed
    # the amber "Unmatched" badge — reads as a matcher failure when the match
    # exists. Such lines must say "Match available" instead.
    it 'labels teaser-backed unmatched lines "Match available", not "Unmatched"' do
      supplier = create(:supplier, name: 'ConnectedSup')
      sl = create(:supplier_list, supplier: supplier, organization: org, location: location)
      sli = create(:supplier_list_item, supplier_list: sl, sku: 'X1',
                                        supplier_product: create(:supplier_product, supplier: supplier, supplier_sku: 'X1'))
      pm = create(:product_match, aggregated_list: aggregated_list, match_status: 'unmatched')
      create(:product_match_item, product_match: pm, supplier_list_item: sli)

      teaser_supplier = create(:supplier, name: 'TeaserSup')
      TeaserMatch.create!(aggregated_list: aggregated_list, product_match: pm,
                          supplier: teaser_supplier,
                          supplier_product: create(:supplier_product, supplier: teaser_supplier, supplier_sku: 'T1'))

      get aggregated_list_path(aggregated_list)

      expect(response.body).to include('Match available')
      # The amber row badge specifically — the "Unmatched" stats tile label
      # legitimately remains elsewhere on the page
      expect(response.body).not_to include('text-amber-700">Unmatched')
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
