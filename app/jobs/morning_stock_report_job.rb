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
  # reading from this morning. Below it = alert.
  COVERAGE_ALERT_BELOW = 0.85
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
  # { supplier:, mode:, run:, ran_at:, in_use_total:, in_use_checked:, in_use_out:, problems: [] }
  def self.build_report(since: Time.current.beginning_of_day)
    in_use_ids = SupplierListItem.where.not(supplier_product_id: nil).distinct.pluck(:supplier_product_id)

    Supplier.where(active: true).where.not(scraper_class: [nil, '']).order(:name).map do |supplier|
      run = supplier.last_stock_run || {}
      ran_at = begin
        Time.zone.parse(run['at'].to_s)
      rescue ArgumentError
        nil
      end
      in_use = SupplierProduct.where(supplier_id: supplier.id, id: in_use_ids)
      total = in_use.count
      checked = in_use.where('stock_checked_at >= ?', since).count

      {
        supplier: supplier,
        mode: supplier.morning_stock_mode,
        run: run,
        ran_at: ran_at,
        in_use_total: total,
        in_use_checked: checked,
        in_use_out: in_use.where(in_stock: false).count,
        problems: supplier.morning_stock_mode == 'off' ? [] : problems_for(run, ran_at, since, total, checked)
      }
    end
  end

  def self.problems_for(run, ran_at, since, total, checked)
    problems = []
    problems << 'no stock run this morning' if ran_at.nil? || ran_at < since
    problems << "run errors: #{Array(run['errors']).first(2).join('; ')}" if Array(run['errors']).any?

    crawl = run['crawl'] || {}
    if Array(crawl['failed']).any? || Array(crawl['short']).any?
      problems << "crawl came up short (#{crawl['fetched']} of #{crawl['expected']}; " \
                  "short: #{Array(crawl['short']).join(', ').presence || '—'}, failed: #{Array(crawl['failed']).join(', ').presence || '—'})"
    end

    if (held = run['held']).present?
      problems << "this morning's run read #{(held['share'].to_f * 100).round}% of #{held['basis']} as out of stock " \
                  "(normal is a few percent), so EnPlace held it: #{held['held_outs'].to_i} item(s) were NOT marked out " \
                  'and nothing changed for chefs. Likely a reading problem at the supplier or in EnPlace.'
    end

    if total.positive? && (checked.to_f / total) < COVERAGE_ALERT_BELOW
      problems << "only #{checked} of #{total} items on lists got a stock reading (#{(checked * 100.0 / total).round}%)"
    end
    problems
  end

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
