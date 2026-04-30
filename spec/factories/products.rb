FactoryBot.define do
  factory :product do
    sequence(:name) { |n| "Product #{n}" }
    sequence(:normalized_name) { |n| "product #{n}" }
    category { 'Produce' }
    unit_size { '5' }
    unit_type { 'lb' }
  end
end
