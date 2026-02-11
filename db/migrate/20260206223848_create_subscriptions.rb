class CreateSubscriptions < ActiveRecord::Migration[7.1]
  def change
    # Add Stripe fields to users
    add_column :users, :stripe_customer_id, :string
    add_index :users, :stripe_customer_id, unique: true

    # Create subscriptions table
    create_table :subscriptions do |t|
      t.references :user, null: false, foreign_key: true

      # Stripe IDs
      t.string :stripe_subscription_id, null: false
      t.string :stripe_price_id

      # Subscription status
      t.string :status, null: false, default: "incomplete"
      # Possible statuses: incomplete, incomplete_expired, trialing, active,
      #                    past_due, canceled, unpaid, paused

      # Plan details
      t.string :plan_name, default: "pro"
      t.integer :amount_cents, default: 9900 # $99.00
      t.string :currency, default: "usd"
      t.string :interval, default: "month"

      # Billing period
      t.datetime :current_period_start
      t.datetime :current_period_end
      t.datetime :trial_start
      t.datetime :trial_end

      # Cancellation
      t.boolean :cancel_at_period_end, default: false
      t.datetime :canceled_at
      t.datetime :ended_at

      # Metadata
      t.json :metadata, default: {}

      t.timestamps
    end

    add_index :subscriptions, :stripe_subscription_id, unique: true
    add_index :subscriptions, :status
    add_index :subscriptions, [:user_id, :status]

    # Create billing events table for audit trail
    create_table :billing_events do |t|
      t.references :user, foreign_key: true
      t.references :subscription, foreign_key: true

      t.string :stripe_event_id, null: false
      t.string :event_type, null: false
      t.json :data, default: {}
      t.boolean :processed, default: false
      t.text :error_message

      t.timestamps
    end

    add_index :billing_events, :stripe_event_id, unique: true
    add_index :billing_events, :event_type
    add_index :billing_events, :processed

    # Create invoices table
    create_table :invoices do |t|
      t.references :user, null: false, foreign_key: true
      t.references :subscription, foreign_key: true

      t.string :stripe_invoice_id, null: false
      t.string :status, null: false
      t.integer :amount_due_cents
      t.integer :amount_paid_cents
      t.string :currency, default: "usd"
      t.string :hosted_invoice_url
      t.string :invoice_pdf_url
      t.datetime :period_start
      t.datetime :period_end
      t.datetime :paid_at

      t.timestamps
    end

    add_index :invoices, :stripe_invoice_id, unique: true
    add_index :invoices, :status
  end
end
