class CreateSupplierPortalInvitations < ActiveRecord::Migration[7.1]
  def change
    create_table :supplier_portal_invitations do |t|
      t.references :supplier, null: false, foreign_key: true
      t.string :email, null: false
      t.string :role, null: false, default: "rep"
      t.string :token, null: false
      t.references :invited_by, polymorphic: true, null: true
      t.datetime :expires_at, null: false
      t.datetime :accepted_at

      t.timestamps
    end

    add_index :supplier_portal_invitations, :token, unique: true
    add_index :supplier_portal_invitations, [:supplier_id, :email],
              unique: true, name: "idx_supplier_portal_invitations_supplier_email"
  end
end
