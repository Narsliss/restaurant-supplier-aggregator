require 'rails_helper'

RSpec::Matchers.define_negated_matcher :not_change, :change

RSpec.describe TeaserCatalogSearchService do
  let(:user) { create(:user, :with_organization) }
  let(:organization) { user.current_organization }
  let(:location) { create(:location, user: user, organization: organization) }

  # Tiago's setup: 1 credentialed supplier (USF), 2 unconnected (Sysco, WCW)
  let(:usf)   { create(:supplier, name: 'US Foods') }
  let(:sysco) { create(:supplier, name: 'Sysco') }
  let(:wcw)   { create(:supplier, name: 'What Chefs Want') }

  let!(:usf_credential) do
    create(:supplier_credential, user: user, supplier: usf,
           organization: organization, location: location)
  end

  let(:usf_list) do
    SupplierList.create!(
      supplier: usf, supplier_credential: usf_credential,
      organization_id: organization.id, location: location, name: 'USF Order Guide'
    )
  end

  let(:aggregated_list) do
    AggregatedList.create!(
      organization: organization, location_id: location.id, created_by: user,
      name: 'Tiago Matched List', list_type: 'matched', match_status: 'matched'
    )
  end

  before do
    # The seed_suppliers initializer creates the real-world suppliers on every
    # boot. Deactivate them so we only test against the suppliers we set up
    # here — otherwise `unconnected_supplier_ids` picks up Sysco-the-seed,
    # WCW-the-seed, etc., and the counts/teasers don't match expectations.
    Supplier.where.not(id: [usf.id, sysco.id, wcw.id]).update_all(active: false)
    AggregatedListMapping.create!(aggregated_list: aggregated_list, supplier_list: usf_list)
  end

  def make_sli(name:, sku: 'A1')
    usf_list.supplier_list_items.create!(name: name, sku: sku, price: 10.0, pack_size: '1 CS')
  end

  def make_product_match(name:)
    sli = make_sli(name: name, sku: "SKU-#{SecureRandom.hex(3)}")
    pm = aggregated_list.product_matches.create!(
      canonical_name: name, match_status: 'unmatched',
      confidence_score: 0.0, position: aggregated_list.product_matches.count + 1
    )
    pm.product_match_items.create!(supplier_list_item: sli, supplier_id: usf.id, is_primary: true)
    pm
  end

  describe '#call' do
    it 'creates a TeaserMatch for an unconnected supplier whose catalog has a similar product' do
      make_product_match(name: 'Tomato Plum Roma')
      create(:supplier_product, supplier: sysco, supplier_name: 'Tomato Plum Roma 25 LB', current_price: 18.0)

      result = described_class.new(aggregated_list).call

      expect(result[:found]).to eq(1)
      expect(result[:unconnected_suppliers]).to eq(2)
      expect(TeaserMatch.where(aggregated_list: aggregated_list, supplier: sysco).count).to eq(1)
    end

    it 'does not create teasers for the credentialed supplier' do
      pm = make_product_match(name: 'Tomato Plum')
      # A "tomato" SupplierProduct also exists in USF's catalog — but USF is credentialed,
      # so it must not get a teaser. The chef sees USF as a real column, not a teaser.
      create(:supplier_product, supplier: usf, supplier_name: 'Tomato Plum 25 LB')

      described_class.new(aggregated_list).call

      expect(TeaserMatch.where(supplier: usf).count).to eq(0)
      expect(TeaserMatch.where(product_match: pm).pluck(:supplier_id)).not_to include(usf.id)
    end

    it 'skips unconnected suppliers whose catalog has nothing similar (below threshold)' do
      make_product_match(name: 'Tomato Plum')
      # Sysco catalog item has zero word overlap → pre-filter skips it, no teaser created
      create(:supplier_product, supplier: sysco, supplier_name: 'Aluminum Foil Sheet 12x18', current_price: 32.0)

      result = described_class.new(aggregated_list).call

      expect(result[:found]).to eq(0)
      expect(TeaserMatch.where(aggregated_list: aggregated_list).count).to eq(0)
    end

    it 'is idempotent — re-running replaces the previous teaser set' do
      make_product_match(name: 'Onion Yellow Spanish')
      create(:supplier_product, supplier: sysco, supplier_name: 'Onion Yellow Spanish Jumbo', current_price: 22.0)

      described_class.new(aggregated_list).call
      first_count = TeaserMatch.where(aggregated_list: aggregated_list).count
      expect(first_count).to eq(1)

      # Second run with the same data — must not duplicate
      described_class.new(aggregated_list).call

      expect(TeaserMatch.where(aggregated_list: aggregated_list).count).to eq(first_count)
    end

    it 'enforces uniqueness per (product_match, supplier) — only one teaser per slot' do
      make_product_match(name: 'Carrot Baby Peeled')
      # Two Sysco catalog products both match this anchor's name above threshold
      create(:supplier_product, supplier: sysco, supplier_name: 'Carrot Baby Peeled 5 LB', current_price: 14.0)
      create(:supplier_product, supplier: sysco, supplier_name: 'Carrot Baby Peeled 10 LB', current_price: 22.0)

      described_class.new(aggregated_list).call

      # Only ONE teaser per supplier per row — whichever scored highest wins.
      # The UI only renders one cell per (row, supplier) anyway.
      expect(TeaserMatch.where(aggregated_list: aggregated_list, supplier: sysco).count).to eq(1)
    end

    it 'no-ops cleanly when there are no unconnected suppliers' do
      # Credential the chef for the other two suppliers too — none are unconnected
      create(:supplier_credential, user: user, supplier: sysco, organization: organization, location: location)
      create(:supplier_credential, user: user, supplier: wcw,   organization: organization, location: location)
      make_product_match(name: 'Tomato Plum')

      result = described_class.new(aggregated_list).call

      expect(result[:unconnected_suppliers]).to eq(0)
      expect(result[:found]).to eq(0)
      expect(TeaserMatch.where(aggregated_list: aggregated_list).count).to eq(0)
    end

    it 'no-ops cleanly when the aggregated list has no product matches' do
      result = described_class.new(aggregated_list).call

      expect(result[:found]).to eq(0)
      expect(result[:searched]).to eq(0)
    end

    it 'ignores rejected product matches (they are hidden from the chef)' do
      make_product_match(name: 'Tomato Plum').update!(match_status: 'rejected')
      create(:supplier_product, supplier: sysco, supplier_name: 'Tomato Plum 25 LB', current_price: 18.0)

      result = described_class.new(aggregated_list).call

      expect(result[:found]).to eq(0)
    end

    it 'matches via canonical Product link when SupplierProducts share a Product' do
      # Cross-supplier canonical Product — anchor's SupplierProduct and Sysco's SupplierProduct
      # both link to the same Product row. Even if names differ wildly, this is a 0.95 match.
      shared_product = create(:product, name: 'Plum Tomato')
      anchor_sp = create(:supplier_product, supplier: usf, supplier_name: 'TOMATO PLM 25#',
                         product: shared_product)
      sli = usf_list.supplier_list_items.create!(
        name: 'TOMATO PLM 25#', sku: 'X1', price: 10.0, pack_size: '25 LB',
        supplier_product: anchor_sp
      )
      pm = aggregated_list.product_matches.create!(
        canonical_name: 'TOMATO PLM 25#', match_status: 'unmatched',
        confidence_score: 0.0, position: 1
      )
      pm.product_match_items.create!(supplier_list_item: sli, supplier_id: usf.id, is_primary: true)

      create(:supplier_product, supplier: sysco, supplier_name: 'Roma Plum Tomato 25 LB',
             product: shared_product, current_price: 18.0)

      result = described_class.new(aggregated_list).call

      expect(result[:found]).to eq(1)
      tm = TeaserMatch.find_by(aggregated_list: aggregated_list, supplier: sysco)
      expect(tm.confidence_score).to eq(0.95)
    end

    it 'skips discontinued catalog products' do
      make_product_match(name: 'Tomato Plum')
      create(:supplier_product, supplier: sysco, supplier_name: 'Tomato Plum 25 LB',
             current_price: 18.0, discontinued: true)

      result = described_class.new(aggregated_list).call

      expect(result[:found]).to eq(0)
    end

    it 'never creates teasers that could enter the ordering path' do
      # Regression guard for CLAUDE.md "ordering code safety" rule.
      # Teasers must NOT become SupplierListItems, must NOT attach to a SupplierList,
      # and must NOT be reachable via the same code path OrderPlacementService walks.
      make_product_match(name: 'Tomato Plum')
      create(:supplier_product, supplier: sysco, supplier_name: 'Tomato Plum 25 LB', current_price: 18.0)

      expect { described_class.new(aggregated_list).call }
        .to change(TeaserMatch, :count).by(1)
        .and(not_change { SupplierListItem.count })
        .and(not_change { aggregated_list.supplier_list_ids })
    end
  end
end
