FactoryBot.define do
  factory :aggregated_list do
    association :organization
    association :created_by, factory: :user
    location_id { create(:location, organization: organization).id }
    sequence(:name) { |n| "Matched List #{n}" }
    list_type { "matched" }
    match_status { "matched" }
  end

  factory :supplier_list do
    association :supplier
    association :organization
    location { association :location, organization: organization }
    sequence(:name) { |n| "Order Guide #{n}" }
    list_type { "order_guide" }
    sync_status { "synced" }
  end

  factory :supplier_list_item do
    association :supplier_list
    sequence(:name) { |n| "Product #{n}" }
    price { 19.99 }
    pack_size { "6/10 LB" }
    in_stock { true }
    association :supplier_product
  end

  factory :product_match do
    association :aggregated_list
    sequence(:canonical_name) { |n| "Canonical Product #{n}" }
    match_status { "auto_matched" }
    sequence(:position)
  end

  factory :product_match_item do
    association :product_match
    association :supplier_list_item
    supplier { supplier_list_item.supplier_list.supplier }
  end
end
