# frozen_string_literal: true

# Deep (full-catalog) import for a single supplier — paginates every category to
# exhaustion via the supplier's API to capture products the shallow daily import
# misses (it caps each category). Additive + reinstate-only: it never marks
# products discontinued, so a partial crawl can't wrongly wipe the catalog.
#
# Supported by any scraper implementing `scrape_catalog_deep` (What Chefs Want,
# Chef's Warehouse, Premiere Produce One). US Foods is NOT included — its daily
# API import already crawls the full catalog category-by-category. Runs long
# (minutes to a couple hours) — scheduled one-supplier-per-night by
# StaggeredDeepImportJob.
#
# Triggered:
#   - Nightly, rotating one supplier at a time (StaggeredDeepImportJob)
#   - Manually: DeepCatalogImportJob.perform_later(supplier_id)
class DeepCatalogImportJob < ApplicationJob
  queue_as :scraping

  discard_on ActiveRecord::RecordNotFound

  def perform(supplier_id)
    supplier = Supplier.find_by(id: supplier_id)
    return unless supplier

    credential = find_credential(supplier)
    unless credential
      Rails.logger.warn "[DeepCatalogImport] No active super_admin credential for #{supplier.name}, skipping"
      return
    end

    scraper = supplier.scraper_klass.new(credential)
    unless scraper.respond_to?(:scrape_catalog_deep)
      Rails.logger.warn "[DeepCatalogImport] #{supplier.name} scraper doesn't support deep import, skipping"
      return
    end

    # Skip if a regular import is already running for this credential
    if credential.importing?
      Rails.logger.info "[DeepCatalogImport] #{supplier.name} import already running, skipping"
      return
    end

    # Skip if a deep import ran recently (avoids double-runs on manual re-trigger)
    last_deep = credential.respond_to?(:last_deep_import_at) ? credential.last_deep_import_at : nil
    if last_deep.present? && last_deep > 20.hours.ago
      Rails.logger.info "[DeepCatalogImport] #{supplier.name} last deep import #{((Time.current - last_deep) / 3600).round(1)}h ago, skipping"
      return
    end

    started_at = Time.current
    Rails.logger.info "[DeepCatalogImport] Starting deep catalog import for #{supplier.name} at #{started_at.iso8601}"
    credential.update_columns(importing: true, import_status_text: "Deep catalog import: #{supplier.name}...")

    results = ImportSupplierProductsService.new(credential).import_catalog_deep(scraper: scraper)

    elapsed = Time.current - started_at
    Rails.logger.info "[DeepCatalogImport] #{supplier.name} complete in " \
                      "#{format('%.1f', elapsed)}s (#{(elapsed / 60).round(1)} min): " \
                      "#{results[:imported]} new, #{results[:updated]} updated, #{results[:reinstated]} reinstated"
  rescue StandardError => e
    elapsed = started_at ? " after #{format('%.1f', Time.current - started_at)}s" : ''
    Rails.logger.error "[DeepCatalogImport] Failed#{elapsed}: #{e.class.name}: #{e.message}"
    Rails.logger.error e.backtrace&.first(10)&.join("\n")
  ensure
    if credential&.persisted?
      attrs = { importing: false, import_progress: 0, import_total: 0, import_status_text: nil }
      attrs[:last_deep_import_at] = Time.current if credential.respond_to?(:last_deep_import_at)
      credential.update_columns(attrs)
    end
  end

  private

  # Prefer a super_admin credential (broadest catalog access), but fall back to
  # the best available active credential. Catalog browsing works with any
  # logged-in account, and in practice there are no super_admin credentials —
  # without this fallback every deep import would silently skip.
  def find_credential(supplier)
    sa_cred = User.super_admin&.credential_for(supplier)
    return sa_cred if sa_cred&.active? || sa_cred&.status == 'pending'

    best_active_credential(supplier)
  end

  # Mirrors StaggeredSupplierImportJob#best_credential_for: prefer a credential
  # with a live session, else the most recently used active one.
  def best_active_credential(supplier)
    active = SupplierCredential.where(supplier: supplier, status: 'active')
    return nil unless active.exists?

    with_session = active.select(&:session_valid?)
    candidates = with_session.any? ? with_session : active.to_a
    candidates.max_by { |c| c.last_login_at || c.created_at }
  end
end
