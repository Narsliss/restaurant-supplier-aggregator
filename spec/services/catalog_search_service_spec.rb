require 'rails_helper'

RSpec.describe CatalogSearchService do
  # Regression for the duplicate-laundering path seen on the alfios matched
  # list: a rotated order guide leaves split duplicate lines, and catalog
  # search then filled each one with the same sibling-supplier products its
  # original line already had — identical USF+Sysco pairings repeated 4-5x,
  # all looking like legitimate auto-matches.
  let(:org) { create(:organization) }
  let(:user) { create(:user) }
  let(:location) { create(:location, organization: org, user: user) }
  let(:aggregated_list) do
    create(:aggregated_list, organization: org, created_by: user, location_id: location.id)
  end

  let(:usf) { create(:supplier, name: 'US Foods') }
  let(:sysco) { create(:supplier, name: 'Sysco') }

  let(:usf_list) { create(:supplier_list, supplier: usf, organization: org, location: location) }
  let(:sysco_list) { create(:supplier_list, supplier: sysco, organization: org, location: location) }

  let(:spine_product) { Product.create!(name: 'Beef Tenderloin') }

  # Same real-world USF product in two guide generations: two SP rows linked
  # to one spine product.
  let(:usf_sp_old) do
    create(:supplier_product, supplier: usf, supplier_sku: 'USF-1', product: spine_product,
                              supplier_name: 'STOCK YARDS - BEEF TENDERLOIN', current_price: 90.0)
  end
  let(:usf_sp_new) do
    create(:supplier_product, supplier: usf, supplier_sku: 'USF-1B', product: spine_product,
                              supplier_name: 'STOCK YARDS - BEEF TENDERLOIN', current_price: 91.0)
  end
  let!(:sysco_sp) do
    create(:supplier_product, supplier: sysco, supplier_sku: 'SYS-1', product: spine_product,
                              supplier_name: 'CAB BEEF TENDERLOIN PSMO', current_price: 85.0)
  end

  before do
    # SupplierList#auto_add_to_matched_list may have mapped these already
    [usf_list, sysco_list].each do |sl|
      aggregated_list.aggregated_list_mappings.find_or_create_by!(supplier_list: sl)
    end
  end

  def make_match(status:, sli:)
    pm = create(:product_match, aggregated_list: aggregated_list, match_status: status)
    create(:product_match_item, product_match: pm, supplier_list_item: sli)
    pm
  end

  it 'skips and flags an unmatched line whose product already lives on another line' do
    original_sli = create(:supplier_list_item, supplier_list: usf_list, sku: 'USF-1',
                                               supplier_product: usf_sp_old)
    original = make_match(status: 'auto_matched', sli: original_sli)

    duplicate_sli = create(:supplier_list_item, supplier_list: usf_list, sku: 'USF-1B',
                                                supplier_product: usf_sp_new)
    duplicate = make_match(status: 'unmatched', sli: duplicate_sli)

    results = described_class.new(aggregated_list).call

    expect(results[:skipped_duplicates]).to eq(1)
    duplicate.reload
    expect(duplicate.possible_duplicate_of_id).to eq(original.id)
    # The duplicate line must NOT get filled from the catalog
    expect(duplicate.product_match_items.count).to eq(1)
    expect(sysco_list.supplier_list_items.where(source: 'catalog_search')).to be_empty
  end

  it 'still fills a genuinely unique unmatched line from the catalog' do
    unique_sli = create(:supplier_list_item, supplier_list: usf_list, sku: 'USF-1',
                                             supplier_product: usf_sp_old,
                                             name: 'STOCK YARDS - BEEF TENDERLOIN')
    unique = make_match(status: 'unmatched', sli: unique_sli)

    results = described_class.new(aggregated_list).call

    expect(results[:skipped_duplicates]).to eq(0)
    expect(results[:found]).to eq(1)
    # Pass 1 (shared spine product) pairs it with the Sysco catalog product
    expect(unique.reload.product_match_items.map(&:supplier_id)).to match_array([usf.id, sysco.id])
  end
end
