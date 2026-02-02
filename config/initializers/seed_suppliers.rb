# Ensure suppliers are always present in the database.
# Runs on every application boot (server start, console, jobs).
# Uses find_or_create_by to avoid duplicates, and updates attributes
# on existing records so changes here propagate automatically.

Rails.application.config.after_initialize do
  next unless ActiveRecord::Base.connection.table_exists?("suppliers")

  suppliers = [
    {
      code: "usfoods",
      name: "US Foods",
      base_url: "https://www.usfoods.com",
      login_url: "https://www.usfoods.com/sign-in",
      scraper_class: "Scrapers::UsFoodsScraper"
    },
    {
      code: "chefswarehouse",
      name: "Chef's Warehouse",
      base_url: "https://www.chefswarehouse.com",
      login_url: "https://www.chefswarehouse.com/login",
      scraper_class: "Scrapers::ChefsWarehouseScraper"
    },
    {
      code: "whatchefswant",
      name: "What Chefs Want",
      base_url: "https://www.whatchefswant.com",
      login_url: "https://www.whatchefswant.com/customer-login/",
      scraper_class: "Scrapers::WhatChefsWantScraper"
    },
    {
      code: "premiereproduceone",
      name: "Premiere Produce One",
      base_url: "https://premierproduceone.pepr.app",
      login_url: "https://premierproduceone.pepr.app/",
      scraper_class: "Scrapers::PremiereProduceOneScraper"
    }
  ]

  suppliers.each do |attrs|
    supplier = Supplier.find_or_initialize_by(code: attrs[:code])
    supplier.assign_attributes(attrs.merge(active: true))
    supplier.save! if supplier.new_record? || supplier.changed?
  end
rescue ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid => e
  # Database doesn't exist yet (e.g. before db:create) — skip silently
  Rails.logger.debug "[SeedSuppliers] Skipped: #{e.message}"
end
