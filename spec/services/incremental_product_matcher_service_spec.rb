require 'rails_helper'

RSpec.describe IncrementalProductMatcherService do
  let(:user) { create(:user, :with_organization) }
  let(:organization) { user.current_organization }
  let(:location) { create(:location, user: user, organization: organization) }
  let(:supplier) { create(:supplier, name: 'Test Supplier') }
  let(:credential) { create(:supplier_credential, user: user, supplier: supplier, organization: organization, location: location) }
  let(:supplier_list) do
    SupplierList.create!(
      supplier: supplier,
      supplier_credential: credential,
      organization_id: organization.id,
      location: location,
      name: 'Order Guide'
    )
  end
  let(:aggregated_list) do
    AggregatedList.create!(
      organization: organization,
      location_id: location.id,
      created_by: user,
      name: 'Matched List',
      list_type: 'matched',
      match_status: 'pending'
    )
  end

  def make_sli(name:, sku:)
    supplier_list.supplier_list_items.create!(
      name: name, sku: sku, price: 10.0, pack_size: '1 EA'
    )
  end

  before do
    # Disable AI calls so tests are deterministic — no Groq
    stub_const("#{described_class}::SIMILARITY_THRESHOLD", 0.45)
    allow_any_instance_of(described_class).to receive(:call_groq).and_return(nil)
  end

  describe 'per-item failure isolation' do
    # Regression: a single bad item (e.g. uniqueness violation, nil field)
    # used to abort the entire batch via outer rescue, silently dropping
    # every item after the first failure. Customer-visible symptom: 173
    # imported supplier-list items, only 44 ProductMatch rows showed up
    # on the match page. Per-item rescue ensures one bad apple doesn't
    # poison the batch.
    it 'records the error and continues processing remaining items when one item raises' do
      good_a = make_sli(name: 'Tomato Plum', sku: 'A')
      bad   = make_sli(name: 'Onion Yellow', sku: 'B')
      good_b = make_sli(name: 'Lettuce Romaine', sku: 'C')

      # Force the second item's create! to raise — simulates a uniqueness
      # collision or any other AR validation failure during processing.
      service = described_class.new(aggregated_list, items: [good_a, bad, good_b])
      original_create = aggregated_list.product_matches.method(:create!)
      allow(aggregated_list.product_matches).to receive(:create!) do |attrs|
        raise ActiveRecord::RecordInvalid.new(ProductMatch.new) if attrs[:canonical_name] == 'Onion Yellow'

        original_create.call(attrs)
      end

      result = service.call

      expect(result[:total_new]).to eq(2)
      expect(result[:new_unmatched]).to eq(2)
      expect(result[:errored]).to eq(1)
      expect(result[:errors].first).to include("item=#{bad.id}")
      expect(aggregated_list.product_matches.pluck(:canonical_name)).to contain_exactly('Tomato Plum', 'Lettuce Romaine')
    end

    it 'splits a same-supplier match into a separate ProductMatch so it stays visible' do
      # If the similarity/AI pass groups two items from the same supplier
      # into the same ProductMatch within a single run, the supplier slot
      # is already filled when we get to the second item. The service used
      # to silently drop the second item (counted as "matched" but no
      # PMItem created — invisible to the user). It must now create a
      # separate ProductMatch so the item remains visible.
      item_a = make_sli(name: 'Whole Milk', sku: 'M1')
      item_b = make_sli(name: 'Whole Milk 2%', sku: 'M2')

      allow(ProductNormalizer).to receive(:best_similarity).and_return(0.99)

      service = described_class.new(aggregated_list, items: [item_a, item_b])
      result = service.call

      expect(result[:errored]).to eq(0)
      expect(result[:total_new]).to eq(2)
      expect(result[:split]).to eq(1)
      expect(aggregated_list.product_matches.count).to eq(2)
      expect(aggregated_list.unmatched_supplier_items_count).to eq(0)
    end

    it 'splits a cross-supplier slot conflict into a separate ProductMatch' do
      # Pre-existing match with one US Foods item already in its slot
      other_supplier = create(:supplier, name: 'Other Supplier')
      other_list = SupplierList.create!(supplier: other_supplier, organization_id: organization.id,
                                         location: location, name: 'Other')
      existing_sli = other_list.supplier_list_items.create!(name: 'Mozzarella Shredded', sku: 'X', price: 5.0, pack_size: '1 LB')
      pm = aggregated_list.product_matches.create!(
        canonical_name: 'Mozzarella Shredded', match_status: 'unmatched', confidence_score: 0.0, position: 1
      )
      pm.product_match_items.create!(supplier_list_item: existing_sli, supplier_id: other_supplier.id, is_primary: true)

      # Now add a same-supplier item that the matcher will group with that match
      new_dupe = other_list.supplier_list_items.create!(name: 'Mozzarella Shredded Bulk', sku: 'Y', price: 6.0, pack_size: '1 LB')
      allow(ProductNormalizer).to receive(:best_similarity).and_return(0.99)

      service = described_class.new(aggregated_list, items: [new_dupe])
      result = service.call

      expect(result[:errored]).to eq(0)
      expect(result[:split]).to eq(1)
      expect(result[:new_matched]).to eq(0)
      expect(result[:new_unmatched]).to eq(1)
      # New item got its own ProductMatch — it's visible, not lost
      expect(aggregated_list.product_matches.count).to eq(2)
      expect(aggregated_list.unmatched_supplier_items_count).to eq(0)
    end
  end

  describe 'normal happy-path' do
    it 'creates a ProductMatch per new item when no existing matches exist' do
      # Names must be dissimilar enough to fall below SIMILARITY_THRESHOLD
      items = [
        make_sli(name: 'Tomato Plum', sku: 'S0'),
        make_sli(name: 'Onion Yellow Spanish', sku: 'S1'),
        make_sli(name: 'Carrot Baby Peeled', sku: 'S2')
      ]

      result = described_class.new(aggregated_list, items: items).call

      expect(result[:total_new]).to eq(3)
      expect(result[:new_unmatched]).to eq(3)
      expect(result[:errored]).to eq(0)
      expect(aggregated_list.product_matches.count).to eq(3)
    end

    it 'no-ops cleanly when there are no new items' do
      result = described_class.new(aggregated_list, items: []).call

      expect(result[:total_new]).to eq(0)
      expect(aggregated_list.reload.match_status).to eq('matched')
    end
  end
end
