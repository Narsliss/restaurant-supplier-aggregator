class CreateSupplierLists < ActiveRecord::Migration[7.1]
  def change
    create_table :supplier_lists do |t|
      t.references :supplier_credential, null: false, foreign_key: { on_delete: :cascade }
      t.references :supplier, null: false, foreign_key: { on_delete: :cascade }
      t.references :organization, null: false, foreign_key: true
      t.string :remote_list_id
      t.string :remote_list_url
      t.string :name, null: false
      t.string :list_type, default: 'order_guide', null: false
      t.integer :product_count, default: 0
      t.datetime :last_synced_at
      t.string :sync_status, default: 'pending', null: false
      t.text :sync_error

      t.timestamps
    end

    add_index :supplier_lists, %i[supplier_credential_id remote_list_id], unique: true,
                                                                          name: 'idx_supplier_lists_cred_remote'
    add_index :supplier_lists, :sync_status
  end
end
