class CreateOrganizationsAndMemberships < ActiveRecord::Migration[7.1]
  def change
    # Organizations (Companies/Restaurants)
    create_table :organizations do |t|
      t.string :name, null: false
      t.string :slug, null: false # URL-friendly identifier
      t.string :phone
      t.text :address
      t.string :city
      t.string :state
      t.string :zip_code
      t.string :timezone, default: "America/New_York"

      # Billing - organization owns the subscription
      t.string :stripe_customer_id

      # Settings
      t.jsonb :settings, default: {}

      # Status
      t.boolean :active, default: true
      t.datetime :suspended_at

      t.timestamps
    end

    add_index :organizations, :slug, unique: true
    add_index :organizations, :stripe_customer_id, unique: true

    # Organization Memberships (join table between users and organizations)
    create_table :memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :organization, null: false, foreign_key: true

      # Role within the organization
      t.string :role, null: false, default: "member"
      # Roles: owner, admin, manager, member

      # Invitation tracking
      t.string :invitation_token
      t.datetime :invitation_sent_at
      t.datetime :invitation_accepted_at
      t.string :invited_by_id

      # Status
      t.boolean :active, default: true
      t.datetime :deactivated_at

      t.timestamps
    end

    add_index :memberships, [:user_id, :organization_id], unique: true
    add_index :memberships, :invitation_token, unique: true
    add_index :memberships, :role

    # Organization Invitations (for pending invites before user exists)
    create_table :organization_invitations do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :invited_by, null: false, foreign_key: { to_table: :users }

      t.string :email, null: false
      t.string :role, null: false, default: "member"
      t.string :token, null: false
      t.datetime :expires_at, null: false
      t.datetime :accepted_at

      t.timestamps
    end

    add_index :organization_invitations, :token, unique: true
    add_index :organization_invitations, [:organization_id, :email], unique: true

    # Add organization reference to existing tables
    add_reference :users, :current_organization, foreign_key: { to_table: :organizations }

    # Move subscription ownership from user to organization
    add_reference :subscriptions, :organization, foreign_key: true

    # Organization owns locations (restaurants can have multiple locations)
    add_reference :locations, :organization, foreign_key: true

    # Organization owns supplier credentials (shared across team)
    add_reference :supplier_credentials, :organization, foreign_key: true

    # Organization owns order lists
    add_reference :order_lists, :organization, foreign_key: true

    # Organization owns orders
    add_reference :orders, :organization, foreign_key: true

    # Organization owns invoices
    add_reference :invoices, :organization, foreign_key: true
  end
end
