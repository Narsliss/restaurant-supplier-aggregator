require 'rails_helper'

RSpec.describe StaggeredDeepImportJob, type: :job do
  # 2026-01-04 is a Sunday (wday 0) → the first deep-capable supplier's weekday.
  # 2026-01-05 is a Monday (wday 1).
  let(:sunday) { Time.zone.local(2026, 1, 4) }
  let(:monday) { Time.zone.local(2026, 1, 5) }

  it 'enqueues one deep-capable supplier on its scheduled weekday' do
    captured_id = nil
    allow(DeepCatalogImportJob).to receive(:perform_later) { |id| captured_id = id }

    travel_to(sunday) { described_class.perform_now }

    expect(captured_id).to be_present
    expect(Supplier.find(captured_id).scraper_klass.instance_methods).to include(:scrape_catalog_deep)
  end

  it 'is idle on evenings past the deep-capable supplier count (weekly cadence)' do
    only_one = Supplier.find_by(scraper_class: 'Scrapers::WhatChefsWantScraper') ||
               create(:supplier, scraper_class: 'Scrapers::WhatChefsWantScraper')
    allow(Supplier).to receive(:active).and_return(Supplier.where(id: only_one.id)) # exactly 1 deep-capable

    expect(DeepCatalogImportJob).not_to receive(:perform_later)

    travel_to(monday) { described_class.perform_now } # wday 1 >= 1 supplier → idle
  end

  it 'excludes US Foods (its daily API import already crawls the full catalog)' do
    usf = Supplier.find_by(code: 'usfoods') || create(:supplier, code: 'usfoods', scraper_class: 'Scrapers::UsFoodsScraper')
    expect(usf.scraper_klass.instance_methods).not_to include(:scrape_catalog_deep)
  end

  it 'enqueues nothing when no active supplier is deep-capable' do
    base_only = create(:supplier, scraper_class: 'Scrapers::BaseScraper', active: true)
    allow(Supplier).to receive(:active).and_return(Supplier.where(id: base_only.id))

    expect(DeepCatalogImportJob).not_to receive(:perform_later)

    travel_to(sunday) { described_class.perform_now }
  end
end
