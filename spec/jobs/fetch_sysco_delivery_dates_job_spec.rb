require "rails_helper"

# Supplier-provided delivery dates (Sysco, and Performance since Sep 27 2026).
# Performance answers definitively: dates, or its own reason there are none —
# alfios: "You are not currently set up for deliveries…". Both are stored so
# the order builder can warn before a cart is built.
RSpec.describe FetchSyscoDeliveryDatesJob do
  let(:performance) { Supplier.find_by(code: "performance") || create(:supplier, name: "Performance", code: "performance") }
  let(:credential) { create(:supplier_credential, supplier: performance, status: "active") }
  let(:scraper) { instance_double(Scrapers::PerformanceScraper) }

  before do
    allow_any_instance_of(Supplier).to receive(:scraper_klass).and_return(double(new: scraper))
  end

  it "stores Performance's delivery dates" do
    allow(scraper).to receive(:delivery_dates_result).and_return(dates: %w[2026-09-29 2026-10-02], error: nil)

    described_class.perform_now(credential.id, force: true)

    expect(credential.reload).to have_attributes(available_delivery_dates: %w[2026-09-29 2026-10-02],
                                                 delivery_dates_error: nil)
    expect(credential.delivery_dates_fetched_at).to be_present
  end

  it "stores Performance's reason when it won't deliver to the account" do
    credential.update_columns(available_delivery_dates: %w[2026-09-29])
    msg = "You are not currently set up for deliveries. Please contact your Sales Representative."
    allow(scraper).to receive(:delivery_dates_result).and_return(dates: [], error: msg)

    described_class.perform_now(credential.id, force: true)

    expect(credential.reload).to have_attributes(available_delivery_dates: [], delivery_dates_error: msg)
  end

  it "keeps the previous dates when Performance can't be reached" do
    credential.update_columns(available_delivery_dates: %w[2026-09-29])
    allow(scraper).to receive(:delivery_dates_result).and_raise(Scrapers::PerformanceApi::ApiError, "HTTP 500")

    described_class.perform_now(credential.id, force: true) # retry_on re-enqueues; nothing stored

    expect(credential.reload.available_delivery_dates).to eq(%w[2026-09-29])
    expect(credential.delivery_dates_error).to be_nil
  end

  # Oct 21 2026 (Sentry): when the saved Performance session can't be resumed
  # the job used to retry and then alert. The 2-hourly session refresh logs
  # Performance back in; this job, run from page views, must not.
  context "when the saved Performance session has expired" do
    before do
      credential.update_columns(available_delivery_dates: %w[2026-09-29],
                                delivery_dates_fetched_at: 5.hours.ago)
      allow(scraper).to receive(:delivery_dates_result)
        .and_raise(Scrapers::PerformanceApi::AuthError, "Performance API session expired — re-login required")
    end

    it "keeps the stored dates and finishes quietly, without a retry or an alert" do
      expect { described_class.perform_now(credential.id, force: true) }
        .not_to have_enqueued_job(described_class)

      credential.reload
      expect(credential.available_delivery_dates).to eq(%w[2026-09-29])
      expect(credential.delivery_dates_error).to be_nil
      expect(credential.delivery_dates_fetched_at).to be < 4.hours.ago # still stale, so the next page view asks again
    end

    it "leaves the login itself alone: no failed status, no browser login from here" do
      expect(scraper).not_to receive(:login)
      expect(scraper).not_to receive(:soft_refresh)

      described_class.perform_now(credential.id, force: true)

      expect(credential.reload.status).to eq("active")
    end
  end

  it "still retries when Performance is unreachable (not a login problem)" do
    allow(scraper).to receive(:delivery_dates_result).and_raise(Scrapers::PerformanceApi::ApiError, "HTTP 500")

    expect { described_class.perform_now(credential.id, force: true) }
      .to have_enqueued_job(described_class)
  end
end
