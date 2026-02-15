# frozen_string_literal: true

# Monitors supplier health proactively and sends daily summaries
class SupplierHealthCheckJob < ApplicationJob
  queue_as :low

  def perform
    check_credential_health
    check_import_health
    send_daily_summary_if_needed
  end

  private

  def check_credential_health
    Supplier.active.includes(:supplier_credentials).find_each do |supplier|
      check_supplier_credentials(supplier)
    end
  end

  def check_supplier_credentials(supplier)
    # Only check super_admin credentials (the ones used for scraping)
    super_admin = User.super_admin
    return unless super_admin

    credential = super_admin.credential_for(supplier)
    return unless credential

    # Check if credential is expired or about to expire
    if credential.expired?
      handle_expired_credential(supplier, credential)
    elsif credential.status == 'active' && credential.last_login_at < 20.hours.ago
      # Credential active but hasn't been refreshed in 20+ hours
      # This is a warning - session might expire soon
      handle_stale_credential(supplier, credential)
    end
  end

  def handle_expired_credential(supplier, credential)
    # Only email once per day for the same expired credential
    last_alert = Rails.cache.read("credential_expired_alert:#{credential.id}")
    return if last_alert && last_alert > 24.hours.ago

    ScrapingErrorMailer.credentials_expired(supplier, credential).deliver_later
    Rails.cache.write("credential_expired_alert:#{credential.id}", Time.current, expires_in: 25.hours)

    Rails.logger.warn "[SupplierHealthCheckJob] Expired credentials alert sent for #{supplier.name}"
  end

  def handle_stale_credential(supplier, credential)
    # Only log, don't email - session refresh should handle this
    Rails.logger.info "[SupplierHealthCheckJob] Stale credential detected for #{supplier.name} (last login: #{credential.last_login_at})"

    # Queue a session refresh if not already scheduled
    return if session_refresh_pending?(credential)

    RefreshSessionJob.perform_later(credential.id)
  end

  def check_import_health
    # Check for suppliers that haven't been imported in the last 24 hours
    Supplier.active.find_each do |supplier|
      last_log = ScrapingLog.last_for_supplier(supplier)

      next unless last_log
      next if last_log.created_at > 24.hours.ago

      # Hasn't been imported in 24+ hours - this might be an issue
      Rails.logger.warn "[SupplierHealthCheckJob] #{supplier.name} hasn't been imported in #{(Time.current - last_log.created_at) / 1.hour} hours"

      # Check if imports are failing repeatedly
      recent_failures = ScrapingLog
                        .for_supplier(supplier)
                        .failed
                        .in_last(24.hours)
                        .count

      if recent_failures >= 3
        Rails.logger.error "[SupplierHealthCheckJob] #{supplier.name} has #{recent_failures} failed imports in last 24h"
        # Could send an alert here if needed
      end
    end
  end

  def send_daily_summary_if_needed
    # Send daily summary at 9 AM (controlled by recurring.yml schedule)
    ScrapingErrorMailer.daily_health_summary.deliver_later
  end

  def session_refresh_pending?(_credential)
    # Check if a refresh job is already queued for this credential
    # This is a simplified check - in production you might use Solid Queue's introspection
    false
  end
end
