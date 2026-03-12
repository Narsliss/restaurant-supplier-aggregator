class AllowNullWebFieldsOnSuppliers < ActiveRecord::Migration[7.1]
  def change
    change_column_null :suppliers, :base_url, true
    change_column_null :suppliers, :login_url, true
    change_column_null :suppliers, :scraper_class, true
  end
end
