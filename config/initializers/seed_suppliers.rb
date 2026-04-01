# Ensure suppliers are always present in the database.
# Runs on every application boot (server start, console, jobs).
# Uses find_or_create_by to avoid duplicates, and updates attributes
# on existing records so changes here propagate automatically.

Rails.application.config.after_initialize do
  # Skip during asset precompilation or when database isn't available
  next if ENV['SECRET_KEY_BASE_DUMMY'].present?

  begin
    ready = Timeout.timeout(10) do
      ActiveRecord::Base.connection.table_exists?('suppliers') &&
        ActiveRecord::Base.connection.column_exists?(:suppliers, :auth_type) &&
        ActiveRecord::Base.connection.column_exists?(:suppliers, :case_pricing)
    end
    next unless ready
  rescue ActiveRecord::ConnectionNotEstablished, Timeout::Error => e
    Rails.logger.warn "[SeedSuppliers] Skipped: #{e.class} — #{e.message}"
    next
  end

  suppliers = [
    {
      code: 'usfoods',
      name: 'US Foods',
      base_url: 'https://order.usfoods.com',
      login_url: 'https://order.usfoods.com',
      scraper_class: 'Scrapers::UsFoodsScraper',
      auth_type: 'two_fa',
      case_pricing: false # USF returns per-unit prices for variable-weight items
    },
    {
      code: 'chefswarehouse',
      name: "Chef's Warehouse",
      base_url: 'https://www.chefswarehouse.com',
      login_url: 'https://www.chefswarehouse.com/login',
      scraper_class: 'Scrapers::ChefsWarehouseScraper',
      auth_type: 'password'
    },
    {
      code: 'whatchefswant',
      name: 'What Chefs Want',
      base_url: 'https://www.whatchefswant.com',
      login_url: 'https://www.whatchefswant.com/customer-login/',
      scraper_class: 'Scrapers::WhatChefsWantScraper',
      auth_type: 'welcome_url'
    },
    {
      code: 'premiereproduceone',
      name: 'Premiere Produce One',
      base_url: 'https://premierproduceone.pepr.app',
      login_url: 'https://premierproduceone.pepr.app/',
      scraper_class: 'Scrapers::PremiereProduceOneScraper',
      auth_type: 'two_fa'
    },
    {
      code: 'sysco',
      name: 'Sysco',
      base_url: 'https://shop.sysco.com',
      login_url: 'https://secure.sysco.com/',
      scraper_class: 'Scrapers::SyscoScraper',
      auth_type: 'password'
    }
  ]

  suppliers.each do |attrs|
    supplier = Supplier.find_or_initialize_by(code: attrs[:code])
    # Derive password_required from auth_type
    password_required = attrs[:auth_type] == 'password'
    merged = attrs.merge(active: true, password_required: password_required)
    # Production: checkout always enabled (real orders).
    # Development/test: checkout disabled (dry-run only).
    # OrderPlacementService also enforces this, but belt-and-suspenders.
    merged[:checkout_enabled] = Rails.env.production?
    supplier.assign_attributes(merged)
    supplier.save! if supplier.new_record? || supplier.changed?
  end
rescue ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid => e
  # Database doesn't exist yet (e.g. before db:create) — skip silently
  Rails.logger.debug "[SeedSuppliers] Skipped: #{e.message}"
end
