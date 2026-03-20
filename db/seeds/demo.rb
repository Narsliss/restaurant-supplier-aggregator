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

require 'zlib'
sql = Zlib::GzipReader.open(dump_path) { |gz| gz.read }

# Execute the entire SQL dump at once — uses COPY format which is
# dramatically faster than individual INSERTs over a network connection
conn.execute(sql)

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

# Scrub supplier credentials — keep them "active" but with fake data
SupplierCredential.update_all(
  session_data: '{"cookies":[]}',
  status: 'active',
  last_synced_at: 1.day.ago
)

# Re-encrypt credential passwords with a dummy value
dummy_ciphertext = SupplierCredential.new(password: 'demo-not-real').password_ciphertext
SupplierCredential.update_all(password_ciphertext: dummy_ciphertext)

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
