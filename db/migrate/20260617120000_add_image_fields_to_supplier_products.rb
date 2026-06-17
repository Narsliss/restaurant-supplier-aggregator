# frozen_string_literal: true

class AddImageFieldsToSupplierProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :supplier_products, :image_source_url, :string
    # unknown | pending | mirrored | none | failed
    add_column :supplier_products, :image_status, :string, default: "unknown", null: false
    add_column :supplier_products, :image_checked_at, :datetime

    add_index :supplier_products, :image_status
  end
end
