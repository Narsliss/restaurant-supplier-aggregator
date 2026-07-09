# frozen_string_literal: true

# Nightly driver for full-catalog deep imports. Deep crawls are heavy (minutes to
# a couple hours each), so we run at most ONE per evening on a WEEKLY cadence:
# each deep-capable supplier gets one fixed weekday (supplier i → weekday i), so
# it deep-crawls once a week. Evenings past the supplier count are idle. One crawl
# at a time, no overlap, minimal API load.
#
# The daily shallow import (StaggeredSupplierImportJob) still runs for every
# supplier every day; this only supplements it with the full catalog weekly.
class StaggeredDeepImportJob < ApplicationJob
  queue_as :scraping

  def perform
    suppliers = deep_capable_suppliers
    if suppliers.empty?
      Rails.logger.info '[StaggeredDeepImport] No deep-capable suppliers, nothing to do'
      return
    end

    # Weekly cadence, at most one supplier per evening: supplier i deep-crawls on
    # weekday i (Sun=0 .. Sat=6). Each supplier runs once a week; evenings past
    # the supplier count are idle. This job is scheduled nightly.
    supplier = suppliers[Date.current.wday]
    unless supplier
      Rails.logger.info "[StaggeredDeepImport] No deep crawl scheduled for #{Date.current.strftime('%A')} " \
                        "(#{suppliers.size} suppliers, one per weekday)"
      return
    end

    Rails.logger.info "[StaggeredDeepImport] #{Date.current.strftime('%A')} deep crawl: #{supplier.name}"
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
