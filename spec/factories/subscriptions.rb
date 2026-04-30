FactoryBot.define do
  factory :subscription do
    user
    organization_id { user.current_organization_id }
    sequence(:stripe_subscription_id) { |n| "sub_#{n}#{SecureRandom.hex(4)}" }
    stripe_price_id { 'price_test' }
    status { 'active' }
    amount_cents { 2900 }
    currency { 'usd' }
    interval { 'month' }
    current_period_start { 1.day.ago }
    current_period_end { 29.days.from_now }

    trait :trialing do
      status { 'trialing' }
      trial_start { 5.days.ago }
      trial_end { 9.days.from_now }
    end

    trait :past_due do
      status { 'past_due' }
    end

    trait :canceled do
      status { 'canceled' }
      canceled_at { 1.day.ago }
    end

    trait :cancel_at_period_end do
      cancel_at_period_end { true }
    end
  end
end
