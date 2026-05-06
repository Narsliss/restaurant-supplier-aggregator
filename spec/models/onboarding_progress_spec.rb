require 'rails_helper'

RSpec.describe OnboardingProgress, type: :model do
  describe '.role_for' do
    it 'returns nil for nil user' do
      expect(described_class.role_for(nil)).to be_nil
    end

    it 'returns nil for super_admin users' do
      user = create(:user, :super_admin)
      expect(described_class.role_for(user)).to be_nil
    end

    it 'returns nil for salespeople' do
      user = create(:user, :salesperson)
      expect(described_class.role_for(user)).to be_nil
    end

    it 'defaults to "owner" for users with no organization yet' do
      user = create(:user)
      expect(user.current_organization).to be_nil
      expect(described_class.role_for(user)).to eq('owner')
    end

    it 'returns "owner" for org owners' do
      user = create(:user, :with_organization)
      expect(described_class.role_for(user)).to eq('owner')
    end

    it 'returns "manager" for managers' do
      user = create(:user)
      org = create(:organization)
      create(:membership, user: user, organization: org, role: 'manager', active: true)
      user.update!(current_organization: org)

      expect(described_class.role_for(user)).to eq('manager')
    end

    it 'returns "chef" for chefs' do
      user = create(:user)
      org = create(:organization)
      create(:membership, user: user, organization: org, role: 'chef', active: true)
      user.update!(current_organization: org)

      expect(described_class.role_for(user)).to eq('chef')
    end

    it 'returns nil when membership is inactive' do
      user = create(:user)
      org = create(:organization)
      create(:membership, user: user, organization: org, role: 'chef', active: false)
      user.update!(current_organization: org)

      expect(described_class.role_for(user)).to be_nil
    end
  end

  describe '.for_user' do
    it 'returns nil when user has no eligible role' do
      user = create(:user, :super_admin)
      expect(described_class.for_user(user)).to be_nil
    end

    it 'builds (without saving) a new record for an eligible user with no progress yet' do
      user = create(:user, :with_organization)

      progress = described_class.for_user(user)

      expect(progress).to be_a(described_class)
      expect(progress).to be_new_record
      expect(progress.role).to eq('owner')
      expect(progress.current_step).to eq('welcome')
    end

    it 'returns the existing record when one is already persisted' do
      user = create(:user, :with_organization)
      existing = described_class.create!(user: user, role: 'owner')

      progress = described_class.for_user(user)

      expect(progress).to eq(existing)
    end

    it 'does not change the role of a persisted record even if the user role changed' do
      user = create(:user, :with_organization)
      described_class.create!(user: user, role: 'chef')

      progress = described_class.for_user(user)

      expect(progress.role).to eq('chef')
    end
  end

  describe 'lifecycle predicates' do
    let(:user) { create(:user, :with_organization) }
    let(:progress) { described_class.create!(user: user, role: 'owner') }

    it 'is in_progress by default' do
      expect(progress).to be_in_progress
      expect(progress).not_to be_completed
      expect(progress).not_to be_dismissed
    end

    it 'becomes dismissed when dismiss! is called' do
      progress.dismiss!
      expect(progress).to be_dismissed
      expect(progress).not_to be_in_progress
    end

    it 'becomes completed when complete! is called' do
      progress.complete!
      expect(progress).to be_completed
      expect(progress).not_to be_in_progress
    end
  end

  describe '#advance_to!' do
    let(:user)     { create(:user, :with_organization) }
    let(:progress) { described_class.create!(user: user, role: 'owner') }

    it 'sets current_step to the new step' do
      progress.advance_to!('organization')
      expect(progress.reload.current_step).to eq('organization')
    end

    it 'records the prior step in completed_steps (skipping welcome)' do
      progress.advance_to!('organization')
      progress.advance_to!('restaurant')

      expect(progress.completed_steps).to eq(['organization'])
    end

    it 'does not duplicate entries in completed_steps when stepping through the same step twice' do
      progress.advance_to!('organization')
      progress.advance_to!('restaurant')
      progress.advance_to!('organization')
      progress.advance_to!('restaurant')

      expect(progress.completed_steps.count('organization')).to eq(1)
      expect(progress.completed_steps.count('restaurant')).to eq(1)
    end

    it 'never adds the welcome step to completed_steps' do
      progress.advance_to!('organization')
      expect(progress.completed_steps).not_to include('welcome')
    end

    it 'returns false and does nothing when already completed' do
      progress.complete!

      expect(progress.advance_to!('something')).to be false
      expect(progress.reload.current_step).to eq('done')
    end

    it 'returns false and does nothing when already dismissed' do
      progress.dismiss!

      expect(progress.advance_to!('something')).to be false
      expect(progress.reload.current_step).to eq('welcome')
    end
  end

  describe '#complete!' do
    let(:user)     { create(:user, :with_organization) }
    let(:progress) { described_class.create!(user: user, role: 'owner') }

    it 'sets current_step to "done" and stamps completed_at' do
      progress.advance_to!('organization')
      progress.complete!

      expect(progress.current_step).to eq('done')
      expect(progress.completed_at).to be_within(1.second).of(Time.current)
    end

    it 'records the final step in completed_steps before marking done' do
      progress.advance_to!('organization')
      progress.complete!

      expect(progress.completed_steps).to include('organization')
    end
  end

  describe '#restart!' do
    let(:user)     { create(:user, :with_organization) }
    let(:progress) { described_class.create!(user: user, role: 'owner') }

    it 'resets state and increments restart_count' do
      progress.advance_to!('organization')
      progress.complete!

      progress.restart!

      expect(progress.current_step).to eq('welcome')
      expect(progress.completed_steps).to be_empty
      expect(progress.completed_at).to be_nil
      expect(progress.dismissed_at).to be_nil
      expect(progress.restart_count).to eq(1)
    end

    it 'works from a dismissed state' do
      progress.dismiss!

      progress.restart!

      expect(progress).to be_in_progress
      expect(progress.restart_count).to eq(1)
    end
  end

  describe '#computed_completed_steps' do
    it 'returns an empty array for an owner with no setup data' do
      user = create(:user)
      progress = described_class.new(user: user, role: 'owner')

      expect(progress.computed_completed_steps).to eq([])
    end

    it 'marks "organization" done once the user has a current_organization' do
      user = create(:user, :with_organization)
      progress = described_class.new(user: user, role: 'owner')

      expect(progress.computed_completed_steps).to include('organization')
    end

    it 'marks "restaurant" done once the org has a location' do
      user = create(:user, :with_organization)
      org = user.current_organization
      create(:location, user: user, organization: org)
      progress = described_class.new(user: user, role: 'owner')

      expect(progress.computed_completed_steps).to include('restaurant')
    end

    it 'marks "team" done when a teammate has been added' do
      user = create(:user, :with_organization)
      org = user.current_organization
      teammate = create(:user)
      create(:membership, user: teammate, organization: org, role: 'manager', active: true)
      progress = described_class.new(user: user, role: 'owner')

      expect(progress.computed_completed_steps).to include('team')
    end

    it 'marks "suppliers" done when the user has an active credential (chef role)' do
      user = create(:user, :with_organization)
      create(:supplier_credential, user: user, status: 'active')
      progress = described_class.new(user: user, role: 'chef')

      expect(progress.computed_completed_steps).to include('suppliers')
    end

    it 'returns empty for a manager regardless of org state (training-only role)' do
      user = create(:user, :with_organization)
      org = user.current_organization
      create(:location, user: user, organization: org)
      progress = described_class.new(user: user, role: 'manager')

      expect(progress.computed_completed_steps).to eq([])
    end
  end

  describe '#effective_completed_steps' do
    it 'merges click-through and computed steps, deduplicated' do
      user = create(:user, :with_organization)
      progress = described_class.create!(user: user, role: 'owner', completed_steps: ['organization', 'welcome-tour'])

      result = progress.effective_completed_steps

      expect(result).to include('organization', 'welcome-tour')
      expect(result.count('organization')).to eq(1) # not duplicated
    end
  end

  describe 'validations' do
    let(:user) { create(:user, :with_organization) }

    it 'requires a role' do
      record = described_class.new(user: user, role: nil)
      expect(record).not_to be_valid
      expect(record.errors[:role]).to be_present
    end

    it 'rejects unknown roles' do
      record = described_class.new(user: user, role: 'admin')
      expect(record).not_to be_valid
      expect(record.errors[:role]).to be_present
    end

    it 'enforces uniqueness of user_id' do
      described_class.create!(user: user, role: 'owner')
      duplicate = described_class.new(user: user, role: 'owner')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:user_id]).to be_present
    end

    it 'sets started_at automatically on create' do
      record = described_class.create!(user: user, role: 'owner')
      expect(record.started_at).to be_within(1.second).of(Time.current)
    end
  end
end
