# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_02_14_162556) do
  create_table "billing_events", force: :cascade do |t|
    t.integer "user_id"
    t.integer "subscription_id"
    t.string "stripe_event_id", null: false
    t.string "event_type", null: false
    t.json "data", default: {}
    t.boolean "processed", default: false
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_type"], name: "index_billing_events_on_event_type"
    t.index ["processed"], name: "index_billing_events_on_processed"
    t.index ["stripe_event_id"], name: "index_billing_events_on_stripe_event_id", unique: true
    t.index ["subscription_id"], name: "index_billing_events_on_subscription_id"
    t.index ["user_id"], name: "index_billing_events_on_user_id"
  end

  create_table "invoices", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "subscription_id"
    t.string "stripe_invoice_id", null: false
    t.string "status", null: false
    t.integer "amount_due_cents"
    t.integer "amount_paid_cents"
    t.string "currency", default: "usd"
    t.string "hosted_invoice_url"
    t.string "invoice_pdf_url"
    t.datetime "period_start"
    t.datetime "period_end"
    t.datetime "paid_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "organization_id"
    t.index ["organization_id"], name: "index_invoices_on_organization_id"
    t.index ["status"], name: "index_invoices_on_status"
    t.index ["stripe_invoice_id"], name: "index_invoices_on_stripe_invoice_id", unique: true
    t.index ["subscription_id"], name: "index_invoices_on_subscription_id"
    t.index ["user_id"], name: "index_invoices_on_user_id"
  end

  create_table "locations", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "name", null: false
    t.text "address"
    t.string "city"
    t.string "state"
    t.string "zip_code"
    t.string "phone"
    t.boolean "is_default", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "organization_id"
    t.index ["organization_id"], name: "index_locations_on_organization_id"
    t.index ["user_id", "is_default"], name: "index_locations_on_user_id_and_is_default"
    t.index ["user_id"], name: "index_locations_on_user_id"
  end

  create_table "memberships", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "organization_id", null: false
    t.string "role", default: "member", null: false
    t.string "invitation_token"
    t.datetime "invitation_sent_at"
    t.datetime "invitation_accepted_at"
    t.string "invited_by_id"
    t.boolean "active", default: true
    t.datetime "deactivated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["invitation_token"], name: "index_memberships_on_invitation_token", unique: true
    t.index ["organization_id"], name: "index_memberships_on_organization_id"
    t.index ["role"], name: "index_memberships_on_role"
    t.index ["user_id", "organization_id"], name: "index_memberships_on_user_id_and_organization_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "order_items", force: :cascade do |t|
    t.integer "order_id", null: false
    t.integer "supplier_product_id", null: false
    t.decimal "quantity", precision: 10, scale: 2, null: false
    t.decimal "unit_price", precision: 10, scale: 2, null: false
    t.decimal "line_total", precision: 10, scale: 2, null: false
    t.string "status", default: "pending"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["status"], name: "index_order_items_on_status"
    t.index ["supplier_product_id"], name: "index_order_items_on_supplier_product_id"
  end

  create_table "order_list_items", force: :cascade do |t|
    t.integer "order_list_id", null: false
    t.integer "product_id", null: false
    t.decimal "quantity", precision: 10, scale: 2, default: "1.0", null: false
    t.text "notes"
    t.integer "position", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_list_id", "position"], name: "index_order_list_items_on_order_list_id_and_position"
    t.index ["order_list_id", "product_id"], name: "index_order_list_items_on_order_list_id_and_product_id", unique: true
    t.index ["order_list_id"], name: "index_order_list_items_on_order_list_id"
    t.index ["product_id"], name: "index_order_list_items_on_product_id"
  end

  create_table "order_lists", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "name", null: false
    t.text "description"
    t.boolean "is_favorite", default: false
    t.datetime "last_used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "organization_id"
    t.index ["organization_id"], name: "index_order_lists_on_organization_id"
    t.index ["user_id", "is_favorite"], name: "index_order_lists_on_user_id_and_is_favorite"
    t.index ["user_id", "last_used_at"], name: "index_order_lists_on_user_id_and_last_used_at"
    t.index ["user_id"], name: "index_order_lists_on_user_id"
  end

  create_table "order_validations", force: :cascade do |t|
    t.integer "order_id", null: false
    t.string "validation_type", null: false
    t.boolean "passed", null: false
    t.text "message"
    t.json "details", default: {}
    t.datetime "validated_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["order_id", "validation_type"], name: "index_order_validations_on_order_id_and_validation_type"
    t.index ["order_id"], name: "index_order_validations_on_order_id"
    t.index ["passed"], name: "index_order_validations_on_passed"
  end

  create_table "orders", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "location_id"
    t.integer "supplier_id", null: false
    t.integer "order_list_id"
    t.string "status", default: "pending", null: false
    t.string "confirmation_number"
    t.decimal "subtotal", precision: 10, scale: 2
    t.decimal "tax", precision: 10, scale: 2
    t.decimal "total_amount", precision: 10, scale: 2
    t.date "delivery_date"
    t.text "notes"
    t.text "error_message"
    t.datetime "submitted_at"
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "organization_id"
    t.index ["confirmation_number"], name: "index_orders_on_confirmation_number"
    t.index ["location_id"], name: "index_orders_on_location_id"
    t.index ["order_list_id"], name: "index_orders_on_order_list_id"
    t.index ["organization_id"], name: "index_orders_on_organization_id"
    t.index ["status"], name: "index_orders_on_status"
    t.index ["submitted_at"], name: "index_orders_on_submitted_at"
    t.index ["supplier_id"], name: "index_orders_on_supplier_id"
    t.index ["user_id", "status"], name: "index_orders_on_user_id_and_status"
    t.index ["user_id", "submitted_at"], name: "index_orders_on_user_id_and_submitted_at"
    t.index ["user_id"], name: "index_orders_on_user_id"
  end

  create_table "organization_invitations", force: :cascade do |t|
    t.integer "organization_id", null: false
    t.integer "invited_by_id", null: false
    t.string "email", null: false
    t.string "role", default: "member", null: false
    t.string "token", null: false
    t.datetime "expires_at", null: false
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["invited_by_id"], name: "index_organization_invitations_on_invited_by_id"
    t.index ["organization_id", "email"], name: "index_organization_invitations_on_organization_id_and_email", unique: true
    t.index ["organization_id"], name: "index_organization_invitations_on_organization_id"
    t.index ["token"], name: "index_organization_invitations_on_token", unique: true
  end

  create_table "organizations", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.string "phone"
    t.text "address"
    t.string "city"
    t.string "state"
    t.string "zip_code"
    t.string "timezone", default: "America/New_York"
    t.string "stripe_customer_id"
    t.json "settings", default: {}
    t.boolean "active", default: true
    t.datetime "suspended_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_organizations_on_slug", unique: true
    t.index ["stripe_customer_id"], name: "index_organizations_on_stripe_customer_id", unique: true
  end

  create_table "products", force: :cascade do |t|
    t.string "name", null: false
    t.string "normalized_name"
    t.string "category"
    t.string "subcategory"
    t.string "unit_size"
    t.string "unit_type"
    t.string "upc"
    t.string "brand"
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category", "subcategory"], name: "index_products_on_category_and_subcategory"
    t.index ["category"], name: "index_products_on_category"
    t.index ["name"], name: "index_products_on_name"
    t.index ["normalized_name"], name: "index_products_on_normalized_name"
    t.index ["upc"], name: "index_products_on_upc"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.text "channel"
    t.text "payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.binary "key", limit: 1024, null: false
    t.binary "value", limit: 536870912, null: false
    t.datetime "created_at", null: false
    t.integer "key_hash", limit: 8, null: false
    t.integer "byte_size", limit: 4, null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "subscriptions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "stripe_subscription_id", null: false
    t.string "stripe_price_id"
    t.string "status", default: "incomplete", null: false
    t.string "plan_name", default: "pro"
    t.integer "amount_cents", default: 9900
    t.string "currency", default: "usd"
    t.string "interval", default: "month"
    t.datetime "current_period_start"
    t.datetime "current_period_end"
    t.datetime "trial_start"
    t.datetime "trial_end"
    t.boolean "cancel_at_period_end", default: false
    t.datetime "canceled_at"
    t.datetime "ended_at"
    t.json "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "organization_id"
    t.index ["organization_id"], name: "index_subscriptions_on_organization_id"
    t.index ["status"], name: "index_subscriptions_on_status"
    t.index ["stripe_subscription_id"], name: "index_subscriptions_on_stripe_subscription_id", unique: true
    t.index ["user_id", "status"], name: "index_subscriptions_on_user_id_and_status"
    t.index ["user_id"], name: "index_subscriptions_on_user_id"
  end

  create_table "supplier_2fa_requests", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "supplier_credential_id", null: false
    t.string "session_token", null: false
    t.string "request_type", null: false
    t.string "two_fa_type"
    t.text "prompt_message"
    t.string "status", default: "pending"
    t.string "code_submitted"
    t.integer "attempts", default: 0
    t.datetime "expires_at", null: false
    t.datetime "verified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["session_token"], name: "index_supplier_2fa_requests_on_session_token", unique: true
    t.index ["status"], name: "index_supplier_2fa_requests_on_status"
    t.index ["supplier_credential_id"], name: "index_supplier_2fa_requests_on_supplier_credential_id"
    t.index ["user_id", "status"], name: "index_supplier_2fa_requests_on_user_id_and_status"
    t.index ["user_id"], name: "index_supplier_2fa_requests_on_user_id"
  end

  create_table "supplier_credentials", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "supplier_id", null: false
    t.text "encrypted_username", null: false
    t.string "encrypted_username_iv", null: false
    t.text "encrypted_password"
    t.string "encrypted_password_iv"
    t.text "encrypted_session_data"
    t.string "encrypted_session_data_iv"
    t.string "status", default: "pending"
    t.datetime "last_login_at"
    t.text "last_error"
    t.boolean "two_fa_enabled", default: false
    t.string "two_fa_type"
    t.text "trusted_device_token"
    t.datetime "trusted_device_expires_at"
    t.boolean "account_on_hold", default: false
    t.string "hold_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "importing", default: false, null: false
    t.datetime "last_import_at"
    t.integer "organization_id"
    t.integer "import_progress", default: 0
    t.integer "import_total", default: 0
    t.string "import_status_text"
    t.index ["organization_id"], name: "index_supplier_credentials_on_organization_id"
    t.index ["status"], name: "index_supplier_credentials_on_status"
    t.index ["supplier_id"], name: "index_supplier_credentials_on_supplier_id"
    t.index ["user_id", "supplier_id"], name: "idx_supplier_creds_unique", unique: true
    t.index ["user_id"], name: "index_supplier_credentials_on_user_id"
  end

  create_table "supplier_delivery_schedules", force: :cascade do |t|
    t.integer "supplier_id", null: false
    t.integer "location_id"
    t.integer "day_of_week", null: false
    t.integer "cutoff_day", null: false
    t.time "cutoff_time", null: false
    t.string "delivery_window"
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["location_id"], name: "index_supplier_delivery_schedules_on_location_id"
    t.index ["supplier_id", "day_of_week"], name: "idx_on_supplier_id_day_of_week_61a293b06b"
    t.index ["supplier_id", "location_id"], name: "idx_on_supplier_id_location_id_5efef46a58"
    t.index ["supplier_id"], name: "index_supplier_delivery_schedules_on_supplier_id"
  end

  create_table "supplier_products", force: :cascade do |t|
    t.integer "product_id"
    t.integer "supplier_id", null: false
    t.string "supplier_sku", null: false
    t.string "supplier_name", null: false
    t.string "supplier_url"
    t.decimal "current_price", precision: 10, scale: 2
    t.decimal "previous_price", precision: 10, scale: 2
    t.string "pack_size"
    t.integer "minimum_quantity", default: 1
    t.integer "maximum_quantity"
    t.boolean "in_stock", default: true
    t.datetime "price_updated_at"
    t.datetime "last_scraped_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["in_stock"], name: "index_supplier_products_on_in_stock"
    t.index ["product_id"], name: "index_supplier_products_on_product_id"
    t.index ["supplier_id", "supplier_sku"], name: "index_supplier_products_on_supplier_id_and_supplier_sku", unique: true
    t.index ["supplier_id"], name: "index_supplier_products_on_supplier_id"
    t.index ["supplier_name"], name: "index_supplier_products_on_supplier_name"
  end

  create_table "supplier_requirements", force: :cascade do |t|
    t.integer "supplier_id", null: false
    t.string "requirement_type", null: false
    t.string "value"
    t.decimal "numeric_value", precision: 10, scale: 2
    t.text "description"
    t.text "error_message", null: false
    t.boolean "is_blocking", default: true
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_supplier_requirements_on_active"
    t.index ["supplier_id", "requirement_type"], name: "idx_on_supplier_id_requirement_type_79869f2f8a"
    t.index ["supplier_id"], name: "index_supplier_requirements_on_supplier_id"
  end

  create_table "suppliers", force: :cascade do |t|
    t.string "name", null: false
    t.string "code", null: false
    t.string "base_url", null: false
    t.string "login_url", null: false
    t.string "scraper_class", null: false
    t.boolean "active", default: true
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "password_required", default: true, null: false
    t.string "auth_type", default: "password", null: false
    t.index ["active"], name: "index_suppliers_on_active"
    t.index ["code"], name: "index_suppliers_on_code", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "current_sign_in_at"
    t.datetime "last_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "last_sign_in_ip"
    t.integer "failed_attempts", default: 0, null: false
    t.string "unlock_token"
    t.datetime "locked_at"
    t.string "role", default: "user"
    t.string "first_name"
    t.string "last_name"
    t.string "phone"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "stripe_customer_id"
    t.integer "current_organization_id"
    t.index ["current_organization_id"], name: "index_users_on_current_organization_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["stripe_customer_id"], name: "index_users_on_stripe_customer_id", unique: true
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
  end

  add_foreign_key "billing_events", "subscriptions"
  add_foreign_key "billing_events", "users"
  add_foreign_key "invoices", "organizations"
  add_foreign_key "invoices", "subscriptions"
  add_foreign_key "invoices", "users"
  add_foreign_key "locations", "organizations"
  add_foreign_key "locations", "users", on_delete: :cascade
  add_foreign_key "memberships", "organizations"
  add_foreign_key "memberships", "users"
  add_foreign_key "order_items", "orders", on_delete: :cascade
  add_foreign_key "order_items", "supplier_products", on_delete: :restrict
  add_foreign_key "order_list_items", "order_lists", on_delete: :cascade
  add_foreign_key "order_list_items", "products", on_delete: :cascade
  add_foreign_key "order_lists", "organizations"
  add_foreign_key "order_lists", "users", on_delete: :cascade
  add_foreign_key "order_validations", "orders", on_delete: :cascade
  add_foreign_key "orders", "locations", on_delete: :nullify
  add_foreign_key "orders", "order_lists", on_delete: :nullify
  add_foreign_key "orders", "organizations"
  add_foreign_key "orders", "suppliers", on_delete: :restrict
  add_foreign_key "orders", "users", on_delete: :cascade
  add_foreign_key "organization_invitations", "organizations"
  add_foreign_key "organization_invitations", "users", column: "invited_by_id"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "subscriptions", "organizations"
  add_foreign_key "subscriptions", "users"
  add_foreign_key "supplier_2fa_requests", "supplier_credentials", on_delete: :cascade
  add_foreign_key "supplier_2fa_requests", "users", on_delete: :cascade
  add_foreign_key "supplier_credentials", "organizations"
  add_foreign_key "supplier_credentials", "suppliers", on_delete: :cascade
  add_foreign_key "supplier_credentials", "users", on_delete: :cascade
  add_foreign_key "supplier_delivery_schedules", "locations", on_delete: :cascade
  add_foreign_key "supplier_delivery_schedules", "suppliers", on_delete: :cascade
  add_foreign_key "supplier_products", "products", on_delete: :nullify
  add_foreign_key "supplier_products", "suppliers", on_delete: :cascade
  add_foreign_key "supplier_requirements", "suppliers", on_delete: :cascade
  add_foreign_key "users", "organizations", column: "current_organization_id"
end
