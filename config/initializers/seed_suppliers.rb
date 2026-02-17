# Ensure suppliers are always present in the database.
# Runs on every application boot (server start, console, jobs).
# Uses find_or_create_by to avoid duplicates, and updates attributes
# on existing records so changes here propagate automatically.

Rails.application.config.after_initialize do
  # Skip during asset precompilation or when database isn't available
  next if ENV['SECRET_KEY_BASE_DUMMY'].present?

  begin
    next unless ActiveRecord::Base.connection.table_exists?('suppliers')
    # Skip if auth_type column doesn't exist yet (migration pending)
    next unless ActiveRecord::Base.connection.column_exists?(:suppliers, :auth_type)
  rescue ActiveRecord::ConnectionNotEstablished
    next
  end

  suppliers = [
    {
      code: 'usfoods',
      name: 'US Foods',
      base_url: 'https://order.usfoods.com',
      login_url: 'https://order.usfoods.com',
      scraper_class: 'Scrapers::UsFoodsScraper',
      auth_type: 'two_fa'
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
    }
  ]

  suppliers.each do |attrs|
    supplier = Supplier.find_or_initialize_by(code: attrs[:code])
    # Derive password_required from auth_type
    password_required = attrs[:auth_type] == 'password'
    supplier.assign_attributes(attrs.merge(active: true, password_required: password_required))
    supplier.save! if supplier.new_record? || supplier.changed?
  end
rescue ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid => e
  # Database doesn't exist yet (e.g. before db:create) — skip silently
  Rails.logger.debug "[SeedSuppliers] Skipped: #{e.message}"
end
