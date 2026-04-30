FactoryBot.define do
  factory :organization do
    sequence(:name) { |n| "Restaurant #{n}" }
    sequence(:slug) { |n| "restaurant-#{n}" }
    address { '123 Main St' }
    city { 'New York' }
    state { 'NY' }
    zip_code { '10001' }
    timezone { 'America/New_York' }
    active { true }
  end
end
