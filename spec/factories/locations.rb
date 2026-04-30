FactoryBot.define do
  factory :location do
    user
    organization
    sequence(:name) { |n| "Location #{n}" }
    address { '123 Main St' }
    city { 'New York' }
    state { 'NY' }
    zip_code { '10001' }
    is_default { false }
  end
end
