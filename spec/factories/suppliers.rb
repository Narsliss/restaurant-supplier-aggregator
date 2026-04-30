FactoryBot.define do
  factory :supplier do
    sequence(:name) { |n| "Supplier #{n}" }
    sequence(:code) { |n| "supplier-#{n}" }
    base_url { 'https://example.com' }
    login_url { 'https://example.com/login' }
    scraper_class { 'Scrapers::BaseScraper' }
    auth_type { 'password' }
    password_required { true }
    active { true }
    checkout_enabled { false }

    trait :two_fa do
      auth_type { 'two_fa' }
      password_required { false }
    end

    trait :email do
      auth_type { 'email' }
      password_required { false }
      base_url { nil }
      login_url { nil }
      scraper_class { nil }
      contact_email { 'orders@email-supplier.example' }
    end

    trait :checkout_enabled do
      checkout_enabled { true }
    end
  end
end
