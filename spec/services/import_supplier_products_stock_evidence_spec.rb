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

  # One import run per example: batches share the run's indexes and held outs.
  def run(items)
    service.send(:prepare_import_indexes!) unless @prepared
    @prepared = true
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

    it "marks items back in as it reads them, and out at the end of the run" do
      run((1..20).map { |i| item("S#{i}", "Steady #{i}", true, '5.0') }) # a normal run around them
      run([item('NW101B', 'Walnuts', false, '0.0'), item('GF210', 'Flour', true, '36.0')])

      expect(flour.reload.in_stock).to be(true)
      expect(walnuts.reload.in_stock).to be(true) # held until the guard has the whole run

      service.send(:apply_held_outs!)
      expect(walnuts.reload.in_stock).to be(false)
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

  # Carmin, Oct 19 2026: live from the first morning with no manual checks.
  # A reader that breaks calls most items out; a real morning, a few percent.
  describe 'the held-outs guard (live mode)' do
    let(:mode) { 'live' }
    let(:list) { create(:supplier_list) }

    # n products on a list, the first `out` of them read out this morning
    def read_list_items(n, out:)
      products = Array.new(n) do |i|
        create(:supplier_product, supplier: supplier, supplier_sku: "L#{i}", supplier_name: "Listed #{i}", in_stock: true).tap do |sp|
          create(:supplier_list_item, supplier_list: list, supplier_product: sp)
        end
      end
      run(products.each_with_index.map { |sp, i| item(sp.supplier_sku, sp.supplier_name, i >= out, i < out ? '0.0' : '9.0') })
      products
    end

    it 'marks items out when a believable share of list items read out' do
      products = read_list_items(20, out: 2) # 10%

      service.send(:finish_stock_run!, double('Scraper', crawl_stats: nil), 'catalog')

      expect(products.first(2).map { |sp| sp.reload.in_stock }).to eq([false, false])
      expect(supplier.reload.last_stock_run).to include('marked_out' => 2, 'held' => nil)
    end

    it 'holds every out, and says so, when too many list items read out' do
      products = read_list_items(20, out: 12) # 60%: a broken reader

      service.send(:finish_stock_run!, double('Scraper', crawl_stats: nil), 'catalog')

      expect(products.map { |sp| sp.reload.in_stock }.uniq).to eq([true])
      expect(supplier.reload.last_stock_run['held']).to include('share' => 0.6, 'basis' => 'list items', 'sample' => 20, 'held_outs' => 12)
      problems = MorningStockReportJob.build_report.find { |r| r[:supplier] == supplier }[:problems]
      expect(problems.join).to include('read 60% of list items as out of stock', '12 item(s) were NOT marked out', 'nothing changed for chefs')
    end

    it 'still marks items back in on a held morning' do
      read_list_items(20, out: 12)
      run([item('GF210', 'Flour', true, '36.0')])

      service.send(:apply_held_outs!)

      expect(flour.reload.in_stock).to be(true)
    end

    it 'falls back to every item read when few list items were read' do
      run([item('NW101B', 'Walnuts', false, '0.0'), item('GF210', 'Flour', false, '0.0')]) # 2 of 2 out, none on lists

      service.send(:apply_held_outs!)

      expect(walnuts.reload.in_stock).to be(true)
      expect(service.instance_variable_get(:@stock_hold)).to include('basis' => 'items read', 'share' => 1.0)
    end

    it 'creates a new item the supplier calls out in stock, then marks it out only if the guard passes' do
      read_list_items(20, out: 0)
      run([item('NEW9', 'Brand New', false, '0.0')])
      created = SupplierProduct.find_by(supplier: supplier, supplier_sku: 'NEW9')
      expect(created.in_stock).to be(true)

      service.send(:apply_held_outs!)

      expect(created.reload.in_stock).to be(false)
    end
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

  # US Foods, Oct 20 2026: ~100 list items come back with no inventory
  # block. The morning report must know they can't be read.
  describe 'items the supplier sends no stock for' do
    let(:list) { create(:supplier_list) }

    before { create(:supplier_list_item, supplier_list: list, supplier_product: flour) }

    it 'names the ones on lists in the run summary' do
      run([item('GF210', 'Flour', nil, nil), item('NW101B', 'Walnuts', nil, nil)]) # walnuts is on no list

      service.send(:record_stock_run!, double('Scraper', crawl_stats: nil), 'catalog')

      expect(supplier.reload.last_stock_run['list_no_stock_data_ids']).to eq([flour.id])
    end

    it 'drops an item the same run read after all (the list-item lookup)' do
      run([item('GF210', 'Flour', nil, nil)])
      scraper = double('Sysco', crawl_stats: nil, live_stock_for: { 'GF210' => [true, '"S" S'] })
      service.send(:read_stock_for_unread_list_items!, scraper)

      service.send(:record_stock_run!, scraper, 'catalog')

      expect(supplier.reload.last_stock_run['list_no_stock_data_ids']).to eq([])
    end
  end

  # docs/fix-morning-sync-at-scale.md: Sysco's 8 AM guide sync reads stock
  # for the guide's items instead of re-importing the catalog per login.
  describe '#read_stock_for_list_items! (a guide sync)' do
    let(:mode) { 'live' }
    let(:scraper) { double('Sysco', crawl_stats: nil) }
    let(:list) { create(:supplier_list) }
    let(:steady) do
      (1..20).map { |i| create(:supplier_product, supplier: supplier, supplier_sku: "S#{i}", in_stock: true) }
    end

    before do
      (steady + [walnuts, flour]).each { |sp| create(:supplier_list_item, supplier_list: list, supplier_product: sp) }
    end

    def read(products)
      service.read_stock_for_list_items!(scraper: scraper, supplier_product_ids: products.map(&:id))
    end

    it 'records the stock and marks outs once the guard passes' do
      answers = steady.to_h { |sp| [sp.supplier_sku, [true, '"S" S']] }
                      .merge('NW101B' => [false, '"O" S'], 'GF210' => [true, '"S" S'])
      allow(scraper).to receive(:live_stock_for).and_return(answers)

      read(steady + [walnuts, flour])

      expect(walnuts.reload).to have_attributes(in_stock: false, stock_signal: '"O" S', stock_source: 'catalog')
      expect(walnuts.stock_checked_at).to be_within(1.minute).of(Time.current)
      expect(flour.reload.in_stock).to be(true)
    end

    it 'holds every out when too many read out (the morning guard)' do
      allow(scraper).to receive(:live_stock_for).and_return(steady.to_h { |sp| [sp.supplier_sku, [false, '"O" S']] })

      read(steady)

      expect(steady.map { |sp| sp.reload.in_stock }).to all(be(true))
    end

    it 'records no stock run, so the 9:15 report keeps judging the 6 AM catalog run' do
      supplier.update!(last_stock_run: { 'at' => 2.hours.ago.iso8601, 'kind' => 'catalog' })
      allow(scraper).to receive(:live_stock_for).and_return('NW101B' => [true, '"S" S'])

      expect { read([walnuts]) }.not_to(change { supplier.reload.last_stock_run })
    end

    it 'looks up only the given items, and skips discontinued ones' do
      flour.update!(discontinued: true)
      expect(scraper).to receive(:live_stock_for).with(['NW101B']).and_return({})

      read([walnuts, flour])
    end

    it 'does nothing in off mode' do
      supplier.update!(morning_stock_mode: 'off')
      expect(scraper).not_to receive(:live_stock_for)

      read([walnuts])
    end

    it 'notes a failed lookup instead of raising' do
      allow(scraper).to receive(:live_stock_for).and_raise(StandardError, 'HTTP 429 for SearchProducts')

      expect { read([walnuts]) }.not_to raise_error
      expect(service.results[:errors].join).to include('HTTP 429')
    end
  end

  # Sysco, Oct 20 2026: the term search missed 142 of 586 list items, so
  # they got no stock reading. Its item-number search reads them.
  describe 'list items the crawl missed' do
    let(:mode) { 'live' }
    let(:list) { create(:supplier_list) }
    let(:scraper) { double('Sysco', crawl_stats: nil) }

    before { [walnuts, flour].each { |sp| create(:supplier_list_item, supplier_list: list, supplier_product: sp) } }

    def read_missed
      service.send(:read_stock_for_unread_list_items!, scraper)
    end

    it 'reads their stock by item number, with the same rules as the crawl' do
      allow(scraper).to receive(:live_stock_for).with(match_array(%w[NW101B GF210]))
                                                 .and_return('NW101B' => [false, '"O" S'], 'GF210' => [true, '"S" S'])

      read_missed

      expect(flour.reload).to have_attributes(in_stock: true, stock_signal: '"S" S', stock_source: 'catalog')
      expect(flour.stock_checked_at).to be_within(1.minute).of(Time.current)
      expect(walnuts.reload).to have_attributes(in_stock: true, stock_signal: '"O" S') # out waits for the guard
      expect(service.send(:held_out_ids)).to include(walnuts.id)
      expect(service.send(:stock_counts)).to include(checked: 2, out: 1)
    end

    it 'only looks up the ones the crawl did not read' do
      run([item('NW101B', 'Walnuts', true, '"S" S')])
      expect(scraper).to receive(:live_stock_for).with(['GF210']).and_return({})

      read_missed
    end

    it 'leaves alone an item the search does not return' do
      allow(scraper).to receive(:live_stock_for).and_return({})

      read_missed

      expect(flour.reload).to have_attributes(in_stock: false, stock_checked_at: nil)
    end

    it 'skips discontinued items' do
      flour.update!(discontinued: true)
      expect(scraper).to receive(:live_stock_for).with(['NW101B']).and_return({})

      read_missed
    end

    it 'records a failed lookup as a run error, for the morning report' do
      allow(scraper).to receive(:live_stock_for).and_raise(StandardError, 'search down')

      read_missed

      expect(service.results[:errors].join).to include('Reading stock for list items failed', 'search down')
    end

    # The doubles above answer live_stock_for whatever its visibility. The
    # real Sysco scraper's lookup was private until Oct 22 2026, so
    # respond_to? was false and the morning run read none of these.
    it 'reads them with the real Sysco scraper' do
      sysco = Scrapers::SyscoScraper.allocate
      allow(sysco).to receive(:logger).and_return(Logger.new(nil))
      allow(sysco).to receive(:graphql_search_products).and_return(
        'results' => [{ 'productId' => 'GF210', 'availableStockInfo' => { 'stockIndicator' => 'S' }, 'productInfo' => {} }]
      )

      service.send(:read_stock_for_unread_list_items!, sysco)

      expect(flour.reload).to have_attributes(in_stock: true, stock_source: 'catalog')
      expect(flour.stock_checked_at).to be_within(1.minute).of(Time.current)
    end

    it 'does nothing for a supplier without the lookup' do
      expect { service.send(:read_stock_for_unread_list_items!, double('Crawler')) }.not_to raise_error
      expect(flour.reload.stock_checked_at).to be_nil
    end

    it 'runs inside the catalog import, before the run is summed up' do
      allow(scraper).to receive(:scrape_catalog).and_return([])
      allow(scraper).to receive(:live_stock_for).and_return('GF210' => [true, '"S" S'])

      service.import_catalog(search_terms: %w[x], scraper: scraper)

      expect(flour.reload.in_stock).to be(true)
      expect(supplier.reload.last_stock_run).to include('stock_checked' => 1, 'would_mark_in' => 1)
    end

    context 'in shadow mode' do
      let(:mode) { 'shadow' }

      it 'marks items in but never out' do
        allow(scraper).to receive(:live_stock_for).and_return('NW101B' => [false, '"O" S'], 'GF210' => [true, '"S" S'])

        read_missed

        expect(flour.reload.in_stock).to be(true)
        expect(walnuts.reload.in_stock).to be(true)
        expect(service.send(:held_out_ids)).to be_empty
      end
    end

    context 'in off mode' do
      let(:mode) { 'off' }

      it 'looks nothing up' do
        expect(scraper).not_to receive(:live_stock_for)

        read_missed
      end
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
