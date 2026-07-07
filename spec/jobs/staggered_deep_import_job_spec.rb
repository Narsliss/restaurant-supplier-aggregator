require 'rails_helper'

RSpec.describe StaggeredDeepImportJob, type: :job do
  it 'enqueues a deep import for a supplier whose scraper supports deep crawling' do
    captured_id = nil
    allow(DeepCatalogImportJob).to receive(:perform_later) { |id| captured_id = id }

    described_class.perform_now

    expect(captured_id).to be_present
    picked = Supplier.find(captured_id)
    expect(picked.scraper_klass.instance_methods).to include(:scrape_catalog_deep)
  end

  it 'enqueues nothing when no active supplier is deep-capable' do
    base_only = create(:supplier, scraper_class: 'Scrapers::BaseScraper', active: true)
    allow(Supplier).to receive(:active).and_return(Supplier.where(id: base_only.id))

    expect(DeepCatalogImportJob).not_to receive(:perform_later)

    described_class.perform_now
  end
end
