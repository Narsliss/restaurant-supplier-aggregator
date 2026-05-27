require 'rails_helper'

RSpec.describe Location, type: :model do
  describe 'after_create_commit :create_default_matched_list' do
    let(:owner) { create(:user) }
    let(:org) do
      o = create(:organization)
      create(:membership, user: owner, organization: o, role: 'owner')
      o
    end

    it 'auto-creates a matched AggregatedList for the new location' do
      expect {
        create(:location, organization: org, created_by: owner, name: 'Riverside')
      }.to change(AggregatedList, :count).by(1)

      agg = AggregatedList.last
      expect(agg.name).to eq('Riverside Matched List')
      expect(agg.list_type).to eq('matched')
      expect(agg.match_status).to eq('pending')
      expect(agg.location_id).to eq(Location.last.id)
      expect(agg.organization).to eq(org)
      expect(agg.created_by).to eq(owner)
    end

    it 'falls back to the org owner when created_by is nil' do
      expect {
        create(:location, organization: org, created_by: nil, name: 'Annex')
      }.to change(AggregatedList, :count).by(1)

      expect(AggregatedList.last.created_by).to eq(owner)
    end

    it 'does not raise if no creator can be determined' do
      orphan_org = create(:organization)
      expect {
        create(:location, organization: orphan_org, created_by: nil, name: 'Orphan')
      }.not_to raise_error
      expect(AggregatedList.where(location_id: Location.last.id)).to be_empty
    end

    it 'does not block location creation when AggregatedList save fails' do
      allow_any_instance_of(AggregatedList).to receive(:save!).and_raise(
        ActiveRecord::RecordInvalid.new(AggregatedList.new)
      )
      expect {
        create(:location, organization: org, created_by: owner, name: 'Failing')
      }.to change(Location, :count).by(1)
    end
  end
end
