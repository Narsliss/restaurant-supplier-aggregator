require 'rails_helper'

# Morning stock run (plan Phase 3, Oct 2026). Catalog runs record what the
# supplier said about stock; supplier.morning_stock_mode decides what changes.
RSpec.describe ImportSupplierProductsService, 'stock evidence' do
  let(:supplier) { create(:supplier, morning_stock_mode: mode) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:service) { described_class.new(credential) }
  let(:mode) { 'shadow' }
  let!(:walnuts) { create(:supplier_product, supplier: supplier, supplier_sku: 'NW101B', supplier_name: 'Walnuts', in_stock: true) }
  let!(:flour) { create(:supplier_product, supplier: supplier, supplier_sku: 'GF210', supplier_name: 'Flour', in_stock: false) }

  def run(items)
    service.send(:prepare_import_indexes!)
    service.import_batch(items)
  end

  def item(sku, name, in_stock, signal)
    { supplier_sku: sku, supplier_name: name, in_stock: in_stock, stock_signal: signal }
  end

  context 'in shadow mode (the default after deploy)' do
    it 'records the evidence but keeps today’s rule: never marks an item out' do
      run([item('NW101B', 'Walnuts', false, '0.0')])

      walnuts.reload
      expect(walnuts.in_stock).to be(true)
      expect(walnuts).to have_attributes(stock_signal: '0.0', stock_source: 'catalog')
      expect(walnuts.stock_checked_at).to be_within(1.minute).of(Time.current)
    end

    it 'counts what live mode would change' do
      run([item('NW101B', 'Walnuts', false, '0.0'), item('GF210', 'Flour', true, '36.0')])

      counts = service.send(:stock_counts)
      expect(counts).to include(checked: 2, out: 1, would_mark_out: 1, would_mark_in: 1)
    end
  end

  context 'in live mode' do
    let(:mode) { 'live' }

    it "marks items out and back in from the supplier's definite answer" do
      run([item('NW101B', 'Walnuts', false, '0.0'), item('GF210', 'Flour', true, '36.0')])

      expect(walnuts.reload.in_stock).to be(false)
      expect(flour.reload.in_stock).to be(true)
    end

    it 'changes nothing when the supplier did not say (nil)' do
      run([item('GF210', 'Flour', nil, nil)])

      expect(flour.reload).to have_attributes(in_stock: false, stock_checked_at: nil)
    end
  end

  context 'in off mode' do
    let(:mode) { 'off' }

    it 'records nothing' do
      run([item('NW101B', 'Walnuts', false, '0.0')])

      expect(walnuts.reload).to have_attributes(in_stock: true, stock_signal: nil, stock_checked_at: nil)
    end
  end

  it 'records evidence on a brand-new item, which lands in stock when the supplier did not say' do
    run([item('NEW1', 'New Thing', nil, nil), item('NEW2', 'Other', false, '0.0')])

    expect(SupplierProduct.find_by(supplier: supplier, supplier_sku: 'NEW1').in_stock).to be(true)
    expect(SupplierProduct.find_by(supplier: supplier, supplier_sku: 'NEW2')).to have_attributes(in_stock: false, stock_signal: '0.0')
  end

  describe 'the run summary (for the morning report)' do
    it 'saves what the run read, including the crawl stats' do
      scraper = double('Scraper', crawl_stats: { 'fetched' => 50, 'expected' => 300, 'short' => ['Seafood'], 'failed' => [] })
      run([item('NW101B', 'Walnuts', false, '0.0')])

      service.send(:record_stock_run!, scraper, 'catalog')

      summary = supplier.reload.last_stock_run
      expect(summary).to include('kind' => 'catalog', 'mode' => 'shadow', 'stock_checked' => 1, 'would_mark_out' => 1,
                                 'credential_id' => credential.id)
      expect(summary['crawl']).to include('short' => ['Seafood'])
    end
  end

  # A worker that booted before web ran the migration doesn't know the
  # evidence columns. The import must still run, without the evidence.
  describe 'before the evidence columns exist' do
    before { allow(SupplierProduct).to receive(:stock_evidence?).and_return(false) }

    it 'imports existing and new items and records no evidence' do
      run([item('NW101B', 'Walnuts', false, '0.0'), item('NEW3', 'Brand New', false, '0.0')])

      expect(walnuts.reload).to have_attributes(in_stock: true, stock_signal: nil, stock_checked_at: nil)
      expect(SupplierProduct.find_by(supplier: supplier, supplier_sku: 'NEW3').stock_signal).to be_nil
      expect(service.send(:stock_counts)[:checked]).to eq(0)
    end
  end

  describe 'miss tracking on a full-catalog browse crawl' do
    it 'is skipped when the scraper says its crawl can miss search-only items' do
      scraper = double('Crawler', skip_miss_tracking?: true, crawl_stats: nil)
      allow(scraper).to receive(:scrape_catalog).and_return([])
      expect(service).not_to receive(:record_misses_for_unseen_products)

      service.import_catalog(search_terms: %w[x], scraper: scraper)
    end
  end
end
