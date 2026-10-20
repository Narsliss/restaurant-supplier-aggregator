# Morning stock report (plan Phase 3, Oct 2026). After the 6 AM catalog runs
# and the 8 AM guide sync, check that every supplier's stock was actually read
# this morning: the run happened, had no errors, the crawl wasn't short, and
# the items restaurants use (on any list) got a stock reading.
#
# Quiet success, alert on failure (Carmin): nothing is sent when all is well.
# Problems email the super admin once a day. The same report feeds the
# Operations page.
#
# Background: until Oct 2026 nobody would have noticed a morning run that
# read nothing — the CW "full" crawl silently read 512 of ~15,900 items on
# some Sundays, and 35 lists sat "syncing" for days with no alert.
class MorningStockReportJob < ApplicationJob
  queue_as :low

  # Share of a supplier's in-use items (on any list) that must have a stock
  # reading from this morning. Below it = alert. Discontinued items and items
  # the supplier sends no stock for don't count: they can never be read, so
  # they made US Foods alarm every morning (Oct 20 2026: 88 discontinued +
  # 100 with no inventory block, while every readable list item was read).
  COVERAGE_ALERT_BELOW = 0.85
  # A supplier normally sends no stock for a few list items (US Foods 14%).
  # Far more than that means its stock reader broke.
  NO_DATA_ALERT_ABOVE = 0.25
  NO_DATA_MIN_SAMPLE = 20
  # Share of the catalog the crawl must fetch, leaving out categories that
  # stop at the deliberate per-category limit (CW Supplies). A few items
  # short across categories with no errors (What Chefs Want, Oct 20: 97%,
  # 99% of list items read) is a page note, not an email.
  CRAWL_ALERT_BELOW = 0.95
  EMAILED_TTL = 2.days

  def perform
    report = self.class.build_report
    problems = report.select { |row| row[:problems].any? }
    return if problems.empty?

    key = "morning_stock_report_emailed:#{Date.current.iso8601}"
    return if cache_read(key)

    ScrapingErrorMailer.morning_stock_problems(problems).deliver_now
    cache_write(key, true)
    Rails.logger.warn "[MorningStockReport] #{problems.size} supplier(s) with problems: " \
                      "#{problems.map { |r| "#{r[:supplier].name}: #{r[:problems].join('; ')}" }.join(' | ')}"
  rescue StandardError => e
    Rails.logger.error "[MorningStockReport] #{e.class}: #{e.message}"
  end

  # One row per scraped supplier:
  # { supplier:, mode:, run:, ran_at:, in_use_total:, in_use_checked:, in_use_no_data:, in_use_out:,
  #   problems: [] (emailed), notes: [] (Operations page only) }
  def self.build_report(since: Time.current.beginning_of_day)
    in_use_ids = SupplierListItem.where.not(supplier_product_id: nil).distinct.pluck(:supplier_product_id)

    Supplier.where(active: true).where.not(scraper_class: [nil, '']).order(:name).map do |supplier|
      run = supplier.last_stock_run || {}
      ran_at = begin
        Time.zone.parse(run['at'].to_s)
      rescue ArgumentError
        nil
      end
      in_use = SupplierProduct.where(supplier_id: supplier.id, id: in_use_ids, discontinued: false)
      total = in_use.count
      checked = in_use.where('stock_checked_at >= ?', since).count
      no_data = if ran_at && ran_at >= since
                  in_use.where(id: Array(run['list_no_stock_data_ids']))
                        .where('stock_checked_at IS NULL OR stock_checked_at < ?', since).count
                else
                  0
                end
      off = supplier.morning_stock_mode == 'off'

      {
        supplier: supplier,
        mode: supplier.morning_stock_mode,
        run: run,
        ran_at: ran_at,
        in_use_total: total,
        in_use_checked: checked,
        in_use_no_data: no_data,
        in_use_out: in_use.where(in_stock: false).count,
        problems: off ? [] : problems_for(run, ran_at, since, total, checked, no_data),
        notes: off ? [] : notes_for(run)
      }
    end
  end

  def self.problems_for(run, ran_at, since, total, checked, no_data = 0)
    problems = []
    problems << 'no stock run this morning' if ran_at.nil? || ran_at < since
    problems << "run errors: #{Array(run['errors']).first(2).join('; ')}" if Array(run['errors']).any?

    crawl = run['crawl'] || {}
    if crawl_short?(crawl)
      problems << "crawl came up short (#{crawl_fetched(crawl)} of #{crawl_expected(crawl)}; " \
                  "short: #{Array(crawl['short']).join(', ').presence || '—'}, failed: #{Array(crawl['failed']).join(', ').presence || '—'})"
    end

    if (held = run['held']).present?
      problems << "this morning's run read #{(held['share'].to_f * 100).round}% of #{held['basis']} as out of stock " \
                  "(normal is a few percent), so EnPlace held it: #{held['held_outs'].to_i} item(s) were NOT marked out " \
                  'and nothing changed for chefs. Likely a reading problem at the supplier or in EnPlace.'
    end

    readable = total - no_data
    if readable.positive? && (checked.to_f / readable) < COVERAGE_ALERT_BELOW
      problems << "only #{checked} of #{readable} items on lists got a stock reading (#{(checked * 100.0 / readable).round}%)"
    end

    if total >= NO_DATA_MIN_SAMPLE && (no_data.to_f / total) > NO_DATA_ALERT_ABOVE
      problems << "the supplier sent no stock for #{no_data} of #{total} items on lists (#{(no_data * 100.0 / total).round}%; " \
                  'normally a few), so its stock reader may have broken'
    end
    problems
  end

  # Worth seeing on the Operations page, not worth an email.
  def self.notes_for(run)
    crawl = run['crawl'] || {}
    notes = []
    capped = Array(crawl['capped'])
    notes << "#{capped.join(', ')} stopped at the 10,000-item category limit (kept on purpose: no big non-food imports)" if capped.any?
    short = Array(crawl['short'])
    notes << "a few items short in #{short.join(', ')}" if short.any? && !crawl_short?(crawl)
    notes
  end

  def self.crawl_short?(crawl)
    return true if Array(crawl['failed']).any?

    expected = crawl_expected(crawl)
    expected.positive? && crawl_fetched(crawl) < expected * CRAWL_ALERT_BELOW
  end

  def self.crawl_fetched(crawl) = crawl['fetched'].to_i - crawl['capped_fetched'].to_i
  def self.crawl_expected(crawl) = crawl['expected'].to_i - crawl['capped_expected'].to_i

  private

  def cache_read(key)
    Rails.cache.read(key)
  rescue StandardError
    nil
  end

  def cache_write(key, value)
    Rails.cache.write(key, value, expires_in: EMAILED_TTL)
  rescue StandardError
    nil
  end
end
