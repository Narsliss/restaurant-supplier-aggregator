# frozen_string_literal: true

class CreateScrapingLogs < ActiveRecord::Migration[7.1]
  def change
    create_table :scraping_logs do |t|
      t.references :supplier, null: false, foreign_key: true
      t.references :supplier_credential, null: true, foreign_key: true
      t.string :job_id
      t.string :status, null: false, default: 'pending'
      t.datetime :started_at
      t.datetime :completed_at
      t.integer :products_imported, default: 0
      t.integer :products_updated, default: 0
      t.text :error_message
      t.json :error_details
      t.json :metadata

      t.timestamps
    end

    add_index :scraping_logs, :status
    add_index :scraping_logs, :started_at
    add_index :scraping_logs, :job_id, unique: true
  end
end
