# frozen_string_literal: true

# Nightly driver for full-catalog deep imports. Deep crawls are heavy (minutes to
# a few hours each), so instead of running them all at once we rotate: ONE
# deep-capable supplier per night. With N such suppliers, each refreshes roughly
# every N days — one deep crawl running at a time, no overlap, minimal API load.
#
# The daily shallow import (StaggeredSupplierImportJob) still runs for every
# supplier every day; this only supplements it with the full catalog.
class StaggeredDeepImportJob < ApplicationJob
  queue_as :scraping

  def perform
    suppliers = deep_capable_suppliers
    if suppliers.empty?
      Rails.logger.info '[StaggeredDeepImport] No deep-capable suppliers, nothing to do'
      return
    end

    # Rotate through the (stable, id-ordered) list one per day.
    supplier = suppliers[Date.current.yday % suppliers.size]
    Rails.logger.info "[StaggeredDeepImport] Tonight's deep crawl: #{supplier.name} " \
                      "(#{suppliers.size} deep-capable suppliers in rotation)"

    DeepCatalogImportJob.perform_later(supplier.id)
  end

  private

  def deep_capable_suppliers
    Supplier.active.order(:id).select do |s|
      klass = s.scraper_klass
      klass.respond_to?(:instance_methods) && klass.instance_methods.include?(:scrape_catalog_deep)
    end
  end
end
