FactoryBot.define do
  factory :supplier_product do
    product
    supplier
    sequence(:supplier_sku) { |n| "SKU-#{n}" }
    sequence(:supplier_name) { |n| "Supplier Product #{n}" }
    current_price { 12.50 }
    pack_size { '1 case' }
    in_stock { true }
    discontinued { false }
  end
end
