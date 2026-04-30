require 'rails_helper'

RSpec.describe User, type: :model do
  describe 'validations' do
    it 'requires first_name and last_name' do
      user = build(:user, first_name: nil, last_name: nil)
      expect(user).not_to be_valid
      expect(user.errors[:first_name]).to be_present
      expect(user.errors[:last_name]).to be_present
    end

    it 'enforces unique email case-insensitively' do
      create(:user, email: 'foo@example.com')
      duplicate = build(:user, email: 'FOO@example.com')
      expect(duplicate).not_to be_valid
    end

    it 'restricts role to user, super_admin, or salesperson' do
      user = build(:user, role: 'wat')
      expect(user).not_to be_valid
    end
  end

  describe 'super_admin uniqueness' do
    it 'allows the first super admin' do
      User.where(role: 'super_admin').destroy_all
      user = build(:user, :super_admin)
      expect(user).to be_valid
    end

    it 'rejects creating a second super admin' do
      User.where(role: 'super_admin').destroy_all
      create(:user, :super_admin)
      duplicate = build(:user, :super_admin)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:role].first).to include('already has a super_admin')
    end

    it 'rejects promoting a regular user to super_admin when one exists' do
      User.where(role: 'super_admin').destroy_all
      create(:user, :super_admin)
      user = create(:user)
      user.role = 'super_admin'
      expect(user.save).to be false
    end
  end

  describe '#full_name' do
    it 'joins first and last' do
      expect(build(:user, first_name: 'A', last_name: 'B').full_name).to eq('A B')
    end

    it 'falls back to email when name is blank' do
      user = build(:user, email: 'who@example.com')
      user.first_name = ''
      user.last_name = ''
      expect(user.full_name).to eq('who@example.com')
    end
  end

  describe 'role helpers' do
    it { expect(build(:user, :super_admin).super_admin?).to be true }
    it { expect(build(:user, :super_admin).platform_admin?).to be true }
    it { expect(build(:user, :salesperson).salesperson?).to be true }
    it { expect(build(:user).super_admin?).to be false }
  end

  describe 'organization helpers' do
    let(:user) { create(:user, :with_organization) }
    let(:org) { user.current_organization }

    it '#has_organization? is true once current_organization is set' do
      expect(user.has_organization?).to be true
    end

    it '#owner_of? when membership role is owner' do
      expect(user.owner_of?(org)).to be true
    end

    it '#manager_of? when membership role is manager or owner' do
      manager = create(:user)
      create(:membership, user: manager, organization: org, role: 'manager')
      expect(manager.manager_of?(org)).to be true
      expect(user.manager_of?(org)).to be true
    end

    it '#member_of? returns true for any active membership' do
      expect(user.member_of?(org)).to be true
    end

    it '#member_of? is true for super_admins regardless of membership' do
      User.where(role: 'super_admin').destroy_all
      sa = create(:user, :super_admin)
      other_org = create(:organization)
      expect(sa.member_of?(other_org)).to be true
    end

    it '#switch_organization! errors if user is not a member' do
      other_org = create(:organization)
      expect { user.switch_organization!(other_org) }.to raise_error(/Not a member/)
    end
  end

  describe '#create_organization!' do
    it 'creates an org, an owner membership, and sets current_organization when nil' do
      user = create(:user)

      org = user.create_organization!(
        name: 'Cucina', slug: 'cucina', address: '1 Way', city: 'NYC', state: 'NY', zip_code: '10001'
      )

      expect(org).to be_persisted
      expect(user.memberships.find_by(organization: org).role).to eq('owner')
      expect(user.reload.current_organization).to eq(org)
    end
  end

  describe '#can_order_from?' do
    let(:user) { create(:user) }
    let(:supplier) { create(:supplier) }

    it 'is true with an active credential, false otherwise' do
      expect(user.can_order_from?(supplier)).to be false
      create(:supplier_credential, user: user, supplier: supplier, status: 'active')
      expect(user.can_order_from?(supplier)).to be true
    end

    it 'is false with an expired credential' do
      create(:supplier_credential, user: user, supplier: supplier, status: 'expired')
      expect(user.can_order_from?(supplier)).to be false
    end
  end
end
