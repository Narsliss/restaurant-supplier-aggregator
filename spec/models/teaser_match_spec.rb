require 'rails_helper'

RSpec.describe TeaserMatch do
  let(:user) { create(:user, :with_organization) }
  let(:organization) { user.current_organization }
  let(:location) { create(:location, user: user, organization: organization) }
  let(:supplier) { create(:supplier) }
  let(:aggregated_list) do
    AggregatedList.create!(
      organization: organization,
      location_id: location.id,
      created_by: user,
      name: 'Matched List',
      list_type: 'matched',
      match_status: 'matched'
    )
  end
  let(:product_match) do
    aggregated_list.product_matches.create!(
      canonical_name: 'Tomato Plum', match_status: 'auto_matched',
      confidence_score: 0.9, position: 1
    )
  end
  let(:supplier_product) { create(:supplier_product, supplier: supplier) }

  describe 'associations' do
    it 'requires aggregated_list, product_match, supplier, supplier_product' do
      tm = TeaserMatch.new
      tm.valid?
      expect(tm.errors[:aggregated_list]).to be_present
      expect(tm.errors[:product_match]).to be_present
      expect(tm.errors[:supplier]).to be_present
      expect(tm.errors[:supplier_product]).to be_present
    end
  end

  describe 'uniqueness' do
    it 'rejects a second teaser for the same (product_match, supplier) pair' do
      TeaserMatch.create!(
        aggregated_list: aggregated_list, product_match: product_match,
        supplier: supplier, supplier_product: supplier_product, confidence_score: 0.7
      )

      other_sp = create(:supplier_product, supplier: supplier)
      dup = TeaserMatch.new(
        aggregated_list: aggregated_list, product_match: product_match,
        supplier: supplier, supplier_product: other_sp, confidence_score: 0.8
      )

      expect(dup).not_to be_valid
      expect(dup.errors[:product_match_id]).to be_present
    end
  end
end
