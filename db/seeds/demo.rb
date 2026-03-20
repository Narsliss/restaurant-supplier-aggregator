# frozen_string_literal: true

# Demo seed script — restores a snapshot of realistic restaurant data
# and scrubs sensitive fields (passwords, credentials, sessions).
#
# Used by:
#   - DemoResetJob (nightly reset)
#   - First boot auto-seed (bin/start)
#   - Manual: rails runner "load Rails.root.join('db/seeds/demo.rb')"

puts "[DemoSeed] Starting demo data restore..."

conn = ActiveRecord::Base.connection

# ── Step 1: Restore data snapshot ──────────────────────────────────────

dump_path = Rails.root.join('db/seeds/demo_data.sql.gz')
unless File.exist?(dump_path)
  puts "[DemoSeed] ERROR: #{dump_path} not found!"
  exit 1
end

puts "[DemoSeed] Decompressing and restoring data snapshot..."

# Use psql directly for COPY format — ActiveRecord can't handle
# the COPY protocol. Pipe the gzipped dump through gunzip | psql.
db_url = ENV['DATABASE_URL']
unless db_url
  puts "[DemoSeed] ERROR: DATABASE_URL not set!"
  exit 1
end

result = system("gunzip -c #{dump_path} | psql '#{db_url}' --quiet --no-psqlrc 2>&1")
unless result
  puts "[DemoSeed] WARNING: psql restore had errors (some may be harmless duplicate key warnings)"
end

puts "[DemoSeed] Data restored."

# ── Step 2: Reset sequence counters ───────────────────────────────────

puts "[DemoSeed] Resetting sequence counters..."
conn.tables.each do |table|
  pk = conn.primary_key(table)
  next unless pk
  conn.execute(<<~SQL) rescue nil
    SELECT setval(
      pg_get_serial_sequence('#{table}', '#{pk}'),
      COALESCE(MAX(#{pk}), 0) + 1,
      false
    ) FROM #{table};
  SQL
end

# ── Step 3: Scrub sensitive data ──────────────────────────────────────

puts "[DemoSeed] Scrubbing credentials and passwords..."

# Set all user passwords to Demo1234!
User.find_each do |user|
  user.update_columns(
    encrypted_password: User.new(password: 'Demo1234!').encrypted_password
  )
end

# Scrub supplier credentials — keep them "active" but with properly
# encrypted fake values (update_all bypasses encryption and creates
# invalid IVs that crash the view on decryption)
# Wipe ALL encrypted fields at the SQL level first. The dump was taken
# from a different environment with a different encryption key, so none
# of the encrypted values can be decrypted here. We must nil everything
# before re-encrypting with the current environment's key.
SupplierCredential.update_all(
  encrypted_username: nil,
  encrypted_username_iv: nil,
  encrypted_password: nil,
  encrypted_password_iv: nil,
  encrypted_session_data: nil,
  encrypted_session_data_iv: nil,
  last_login_at: nil,
  status: 'active'
)

# Now re-encrypt with this environment's key
SupplierCredential.find_each do |cred|
  cred.username = "demo@supplierhub.com"
  cred.password = "demo-password" if cred.supplier&.password_required?
  cred.session_data = nil
  cred.save!(validate: false)
rescue => e
  puts "[DemoSeed] WARNING: Could not scrub credential #{cred.id}: #{e.message}"
end

# ── Step 4: Adjust timestamps so data looks fresh ─────────────────────

puts "[DemoSeed] Freshening timestamps..."

# Shift order dates so the most recent orders are from today/yesterday
# instead of whenever the dump was taken
if Order.any?
  newest_order = Order.maximum(:created_at)
  age = Time.current - newest_order
  shift_days = age.to_i / 1.day

  if shift_days > 1
    conn.execute(<<~SQL)
      UPDATE orders SET
        created_at = created_at + INTERVAL '#{shift_days} days',
        updated_at = updated_at + INTERVAL '#{shift_days} days',
        submitted_at = CASE WHEN submitted_at IS NOT NULL
          THEN submitted_at + INTERVAL '#{shift_days} days'
          ELSE NULL END,
        delivery_date = CASE WHEN delivery_date IS NOT NULL
          THEN delivery_date + INTERVAL '#{shift_days} days'
          ELSE NULL END;
    SQL
    puts "[DemoSeed] Shifted orders forward by #{shift_days} days."
  end
end

puts "[DemoSeed] Demo data restore complete!"
puts "[DemoSeed] Users: #{User.count}, Orders: #{Order.count}, Products: #{SupplierProduct.count}"
