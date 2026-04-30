FactoryBot.define do
  factory :supplier_credential do
    user
    supplier
    organization_id { user.current_organization_id }
    username { 'chef@example.com' }
    password { 'Password1!' }
    status { 'active' }

    trait :on_hold do
      status { 'hold' }
      account_on_hold { true }
      hold_reason { 'Manual hold' }
    end

    trait :expired do
      status { 'expired' }
    end
  end
end
