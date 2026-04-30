FactoryBot.define do
  factory :membership do
    user
    organization
    role { 'owner' }
    active { true }
  end
end
