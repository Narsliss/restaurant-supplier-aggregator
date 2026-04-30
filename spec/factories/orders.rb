FactoryBot.define do
  factory :order do
    user
    supplier
    organization { user.current_organization || association(:organization) }
    status { 'pending' }
    delivery_date { 3.days.from_now.to_date }
    subtotal { 0 }
    total_amount { 0 }

    trait :submitted do
      status { 'submitted' }
      submitted_at { Time.current }
      confirmation_number { 'CONF-123' }
      total_amount { 100.00 }
    end

    trait :confirmed do
      status { 'confirmed' }
      submitted_at { 1.day.ago }
      confirmed_at { Time.current }
      confirmation_number { 'CONF-456' }
      total_amount { 100.00 }
    end

    trait :dry_run_complete do
      status { 'dry_run_complete' }
      submitted_at { Time.current }
      total_amount { 100.00 }
    end

    trait :failed do
      status { 'failed' }
      error_message { 'Something went wrong' }
    end

    trait :draft do
      status { 'draft' }
      draft_saved_at { Time.current }
    end
  end
end
