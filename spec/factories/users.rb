FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    password { 'Password1!' }
    password_confirmation { 'Password1!' }
    first_name { 'Test' }
    last_name { 'User' }
    role { 'user' }

    trait :with_organization do
      after(:create) do |user|
        org = create(:organization)
        create(:membership, user: user, organization: org, role: 'owner')
        user.update!(current_organization: org)
      end
    end

    # User that satisfies onboarding gates AND subscription gates so request specs
    # can hit gated controllers without 302-redirecting to onboarding/subscription.
    # - Owner role
    # - Org with one location
    # - A second active membership (satisfies "must have invited team")
    # - Complimentary subscription (bypasses billing check)
    trait :fully_onboarded do
      after(:create) do |user|
        org = create(:organization, complimentary: true, complimentary_granted_at: Time.current)
        create(:membership, user: user, organization: org, role: 'owner')
        user.update!(current_organization: org)
        create(:location, user: user, organization: org, is_default: true)
        teammate = create(:user)
        create(:membership, user: teammate, organization: org, role: 'manager', active: true)
      end
    end

    trait :super_admin do
      role { 'super_admin' }
      sequence(:email) { |n| "admin#{n}@example.com" }
    end

    trait :salesperson do
      role { 'salesperson' }
    end
  end
end
