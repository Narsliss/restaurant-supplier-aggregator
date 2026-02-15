# frozen_string_literal: true

class ScrapingErrorMailer < ApplicationMailer
  default to: -> { User.super_admin&.email }

  # Immediate alert when import fails
  def import_failed(supplier, error, credential = nil)
    @supplier = supplier
    @error = error
    @credential = credential
    @super_admin = User.super_admin

    # Fallback if no super_admin exists
    return unless @super_admin

    @error_details = {
      supplier: supplier.name,
      error_class: error.class.name,
      error_message: error.message,
      occurred_at: Time.current.strftime('%Y-%m-%d %H:%M:%S %Z'),
      credential_status: credential&.status || 'N/A',
      credential_last_login: credential&.last_login_at&.strftime('%Y-%m-%d %H:%M:%S') || 'N/A'
    }

    subject = "[URGENT] Product Import Failed for #{supplier.name}"

    mail(
      to: @super_admin.email,
      subject: subject
    )
  end

  # Alert when no credentials exist for a supplier
  def no_credentials(supplier)
    @supplier = supplier
    @super_admin = User.super_admin

    return unless @super_admin

    @setup_url = Rails.application.routes.url_helpers.suppliers_url

    mail(
      to: @super_admin.email,
      subject: "[ACTION REQUIRED] Missing Credentials for #{supplier.name}"
    )
  end

  # Alert when no super_admin exists
  def no_super_admin
    # This is a special case - we can't use the default 'to' since there's no super_admin
    # Send to all admin emails from environment or fallback
    admin_email = ENV['ADMIN_EMAIL'] || ENV['DEFAULT_FROM_EMAIL']

    return unless admin_email

    @app_name = 'SupplierHub'

    mail(
      to: admin_email,
      subject: '[CRITICAL] No Super Admin Configured'
    )
  end

  # Daily summary of all supplier health
  def daily_health_summary
    @super_admin = User.super_admin
    return unless @super_admin

    @suppliers = Supplier.active.includes(:supplier_credentials)
    @failed_imports = ScrapingLog.failed.in_last(24.hours)
    @recent_imports = ScrapingLog.completed.in_last(24.hours)

    @summary = {
      total_suppliers: @suppliers.count,
      active_credentials: @suppliers.count { |s| s.supplier_credentials.any?(&:active?) },
      failed_imports_24h: @failed_imports.count,
      successful_imports_24h: @recent_imports.count,
      success_rate: ScrapingLog.success_rate_in_last(24.hours)
    }

    mail(
      to: @super_admin.email,
      subject: "Daily Supplier Health Summary - #{Date.current.strftime('%Y-%m-%d')}"
    )
  end

  # Alert when credential has expired and needs revalidation
  def credentials_expired(supplier, credential)
    @supplier = supplier
    @credential = credential
    @super_admin = User.super_admin

    return unless @super_admin

    @revalidate_url = Rails.application.routes.url_helpers.edit_supplier_path(supplier)

    mail(
      to: @super_admin.email,
      subject: "[ACTION REQUIRED] Credentials Expired for #{supplier.name}"
    )
  end
end
