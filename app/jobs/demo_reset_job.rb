# frozen_string_literal: true

# Resets the demo environment to its golden state every night.
# Truncates all user/business data and re-seeds from the demo snapshot.
#
# Safe in production: returns immediately unless DEMO_MODE=true.
class DemoResetJob < ApplicationJob
  queue_as :critical

  def perform
    unless ENV['DEMO_MODE'] == 'true'
      Rails.logger.info "[DemoResetJob] Not in demo mode — skipping."
      return
    end

    Rails.logger.info "[DemoResetJob] Nightly reset starting..."

    conn = ActiveRecord::Base.connection

    # Tables managed by initializers or Rails internals — don't truncate
    skip = %w[
      schema_migrations
      ar_internal_metadata
      suppliers
      supplier_requirements
    ]

    # Disable foreign key checks for clean truncation
    conn.execute("SET session_replication_role = 'replica';")

    (conn.tables - skip).each do |table|
      conn.execute("TRUNCATE TABLE #{table} CASCADE;")
    end

    conn.execute("SET session_replication_role = 'origin';")

    # Re-seed demo data
    load Rails.root.join('db/seeds/demo.rb')

    Rails.logger.info "[DemoResetJob] Nightly reset complete."
  rescue => e
    Rails.logger.error "[DemoResetJob] Reset failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    raise
  end
end
