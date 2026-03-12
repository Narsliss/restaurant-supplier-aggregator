class CreateInboundPriceLists < ActiveRecord::Migration[7.1]
  def change
    create_table :inbound_price_lists do |t|
      t.string :contact_email, null: false
      t.string :message_id
      t.string :pdf_content_hash
      t.string :from_email
      t.string :subject
      t.datetime :received_at, null: false
      t.string :status, null: false, default: 'pending'
      t.text :error_message
      t.jsonb :raw_products_json
      t.string :pdf_file_name
      t.date :list_date
      t.integer :product_count

      t.timestamps
    end

    add_index :inbound_price_lists, :message_id, unique: true, where: "message_id IS NOT NULL"
    add_index :inbound_price_lists, [:contact_email, :pdf_content_hash], unique: true,
              where: "pdf_content_hash IS NOT NULL", name: 'idx_inbound_price_lists_dedup'
    add_index :inbound_price_lists, :contact_email
    add_index :inbound_price_lists, [:contact_email, :received_at]
  end
end
