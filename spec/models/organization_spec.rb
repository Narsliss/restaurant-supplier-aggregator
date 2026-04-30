require 'rails_helper'

RSpec.describe Organization, type: :model do
  describe 'validations' do
    it 'requires name, address, city, state, zip_code' do
      org = build(:organization, name: nil, address: nil, city: nil, state: nil, zip_code: nil)
      expect(org).not_to be_valid
      expect(org.errors[:name]).to be_present
      expect(org.errors[:address]).to be_present
      expect(org.errors[:city]).to be_present
      expect(org.errors[:state]).to be_present
      expect(org.errors[:zip_code]).to be_present
    end

    it 'rejects slugs with uppercase or special characters' do
      org = build(:organization, slug: 'Bad Slug!')
      expect(org).not_to be_valid
      expect(org.errors[:slug]).to be_present
    end

    it 'enforces unique slug' do
      create(:organization, slug: 'unique-slug-1')
      duplicate = build(:organization, slug: 'unique-slug-1')
      expect(duplicate).not_to be_valid
    end
  end

  describe 'role helpers' do
    let(:org) { create(:organization) }
    let(:owner) { create(:user) }
    let(:manager) { create(:user) }
    let(:chef) { create(:user) }
    let(:outsider) { create(:user) }

    before do
      create(:membership, user: owner, organization: org, role: 'owner')
      create(:membership, user: manager, organization: org, role: 'manager')
      create(:membership, user: chef, organization: org, role: 'chef')
    end

    it '#owner returns the user with the owner membership' do
      expect(org.owner).to eq(owner)
    end

    it '#owner? is true only for the owner' do
      expect(org.owner?(owner)).to be true
      expect(org.owner?(manager)).to be false
    end

    it '#manager? is true for owner and manager' do
      expect(org.manager?(owner)).to be true
      expect(org.manager?(manager)).to be true
      expect(org.manager?(chef)).to be false
    end

    it '#member? is true only for active members' do
      expect(org.member?(owner)).to be true
      expect(org.member?(outsider)).to be false
    end

    it '#role_for returns the role string or nil' do
      expect(org.role_for(chef)).to eq('chef')
      expect(org.role_for(outsider)).to be_nil
    end
  end

  describe 'seat management' do
    let(:org) { create(:organization, max_seats: 3, additional_seats: 0) }

    it 'excludes the owner from seat_count' do
      create(:membership, user: create(:user), organization: org, role: 'owner')
      create(:membership, user: create(:user), organization: org, role: 'manager')
      expect(org.seat_count).to eq(1)
    end

    it '#seat_limit sums max_seats and additional_seats' do
      org.update!(additional_seats: 2)
      expect(org.seat_limit).to eq(5)
    end

    it '#seats_available? when seat_count < seat_limit' do
      create(:membership, user: create(:user), organization: org, role: 'owner')
      create(:membership, user: create(:user), organization: org, role: 'manager')
      expect(org.seats_available?).to be true
    end

    it '#seats_remaining clamps at 0' do
      4.times { create(:membership, user: create(:user), organization: org, role: 'manager') }
      expect(org.seats_remaining).to eq(0)
    end
  end

  describe '#subscribed?' do
    let(:org) { create(:organization) }

    it 'returns true when complimentary' do
      org.update!(complimentary: true, complimentary_granted_at: Time.current)
      expect(org.subscribed?).to be true
    end

    it 'returns false when no subscription and not complimentary' do
      expect(org.subscribed?).to be false
    end
  end
end

RSpec.describe Membership, type: :model do
  describe 'validations' do
    it 'requires a valid role' do
      m = build(:membership, role: 'wat')
      expect(m).not_to be_valid
    end

    it 'enforces one membership per (user, organization)' do
      user = create(:user)
      org = create(:organization)
      create(:membership, user: user, organization: org)
      duplicate = build(:membership, user: user, organization: org)
      expect(duplicate).not_to be_valid
    end
  end

  describe 'role predicates' do
    it { expect(build(:membership, role: 'owner').owner?).to be true }
    it { expect(build(:membership, role: 'manager').manager?).to be true }
    it { expect(build(:membership, role: 'chef').chef?).to be true }
  end

  describe '#assigned_locations' do
    let(:org) { create(:organization) }
    let(:user) { create(:user) }
    let!(:loc_a) { create(:location, organization: org, user: user) }
    let!(:loc_b) { create(:location, organization: org, user: user) }

    it 'owners see all org locations implicitly' do
      m = create(:membership, user: user, organization: org, role: 'owner')
      expect(m.assigned_locations).to contain_exactly(loc_a, loc_b)
    end

    it 'managers and chefs see only explicitly assigned locations' do
      m = create(:membership, user: user, organization: org, role: 'chef')
      m.locations << loc_a
      expect(m.assigned_locations).to contain_exactly(loc_a)
    end
  end
end
