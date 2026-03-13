class AddSyscoSupplier < ActiveRecord::Migration[7.1]
  def up
    # Belt-and-suspenders alongside seed_suppliers initializer.
    # The initializer runs on every boot, but this migration provides
    # an explicit audit trail for when Sysco was added.
    execute <<~SQL
      INSERT INTO suppliers (name, code, base_url, login_url, scraper_class, auth_type, password_required, active, checkout_enabled, created_at, updated_at)
      SELECT 'Sysco', 'sysco', 'https://shop.sysco.com', 'https://secure.sysco.com/', 'Scrapers::SyscoScraper', 'password', TRUE, TRUE, TRUE, NOW(), NOW()
      WHERE NOT EXISTS (SELECT 1 FROM suppliers WHERE code = 'sysco')
    SQL
  end

  def down
    execute "DELETE FROM suppliers WHERE code = 'sysco'"
  end
end
