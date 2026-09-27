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
end
