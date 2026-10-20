require 'rails_helper'

# Morning stock report (plan Phase 3): quiet on success, alert on failure.
RSpec.describe MorningStockReportJob do
  let!(:admin) { create(:user, :super_admin) }
  let!(:supplier) { create(:supplier, name: "Chef's Warehouse", morning_stock_mode: 'shadow') }
  let(:list) { create(:supplier_list, supplier: supplier) }
  let!(:on_list) do
    Array.new(4) do |i|
      sp = create(:supplier_product, supplier: supplier, supplier_sku: "S#{i}")
      create(:supplier_list_item, supplier_list: list, supplier_product: sp, sku: "S#{i}", name: "Item #{i}")
      sp
    end
  end

  # The supplier seed creates the real suppliers at boot; only ours is under test.
  before { Supplier.where.not(id: supplier.id).update_all(morning_stock_mode: 'off') }

  def ran(at: Time.current, errors: [], crawl: { 'fetched' => 100, 'expected' => 100, 'short' => [], 'failed' => [] }, no_data: [])
    supplier.update!(last_stock_run: { 'at' => at.iso8601, 'kind' => 'catalog', 'errors' => errors, 'crawl' => crawl,
                                       'list_no_stock_data_ids' => no_data.map(&:id) })
  end

  def read_today(products)
    products.each { |sp| sp.update!(stock_checked_at: Time.current) }
  end

  def row
    described_class.build_report.find { |r| r[:supplier] == supplier }
  end

  def problems = row[:problems]
  def notes = row[:notes]

  # docs/fix-morning-sync-at-scale.md: all supplier traffic leaves from one
  # Railway address; a supplier rate-limiting or blocking us must not go unseen.
  describe 'a supplier refusing us (HTTP 429/403)' do
    before do
      ran
      read_today(on_list)
    end

    it "counts this morning's refusals, raised or caught by the guide sync" do
      ScrapingLog.create!(supplier: supplier, status: 'completed', metadata: { 'errors' => ['HTTP 429 for GetLists'] })
      ScrapingLog.create!(supplier: supplier, status: 'failed', error_message: 'HTTP 403 for Order/V1/GetOrderCart: Forbidden')

      expect(problems).to contain_exactly(a_string_including('refused 2 of this morning'))
    end

    it "ignores other errors and yesterday's refusals" do
      ScrapingLog.create!(supplier: supplier, status: 'failed', error_message: 'HTTP 500 for GetLists')
      ScrapingLog.create!(supplier: supplier, status: 'failed', error_message: 'HTTP 429', created_at: 1.day.ago)

      expect(problems).to eq([])
    end

    it 'reports them even when the supplier has the stock check off' do
      supplier.update!(morning_stock_mode: 'off')
      ScrapingLog.create!(supplier: supplier, status: 'failed', error_message: 'HTTP 429 Too Many Requests')

      expect(problems).to contain_exactly(a_string_including('rate-limiting or blocking EnPlace'))
    end
  end

  it 'finds nothing wrong when the run happened, was complete, and read the items on lists' do
    ran
    read_today(on_list)

    expect(problems).to eq([])
  end

  it 'flags a supplier with no run this morning' do
    ran(at: 1.day.ago)
    read_today(on_list)

    expect(problems).to include('no stock run this morning')
  end

  it 'flags a short crawl (the CW "deep" crawl read 512 of ~15,900 and logged complete)' do
    ran(crawl: { 'fetched' => 512, 'expected' => 15_900, 'short' => %w[Seafood Produce], 'failed' => [] })
    read_today(on_list)

    expect(problems.join).to include('crawl came up short (512 of 15900', 'Seafood, Produce')
  end

  # Oct 20 2026: CW Supplies (~19,500 non-food items) stops at the 10,000
  # limit, and Carmin keeps it there. That is not a short crawl.
  it 'does not email for a category stopped at the limit on purpose, but notes it on the page' do
    ran(crawl: { 'fetched' => 15_574, 'expected' => 25_023, 'short' => [], 'failed' => [],
                 'capped' => ['Supplies'], 'capped_fetched' => 10_000, 'capped_expected' => 19_449 })
    read_today(on_list)

    expect(problems).to eq([])
    expect(notes.join).to include('Supplies stopped at the 10,000-item category limit')
  end

  # What Chefs Want, Oct 20 2026: 6,501 of 6,675 with no errors, 99% of list
  # items read. Every morning's email said "crawl came up short".
  it 'notes, without emailing, a crawl a few items short with no errors' do
    ran(crawl: { 'fetched' => 6_501, 'expected' => 6_675, 'short' => ['Meat > Pork', 'Eggs'], 'failed' => [] })
    read_today(on_list)

    expect(problems).to eq([])
    expect(notes).to include('a few items short in Meat > Pork, Eggs')
  end

  it 'flags a category that failed, however small' do
    ran(crawl: { 'fetched' => 6_600, 'expected' => 6_675, 'short' => [], 'failed' => ['Eggs'] })
    read_today(on_list)

    expect(problems.join).to include('crawl came up short (6600 of 6675', 'failed: Eggs')
  end

  it 'still flags a short crawl once the capped category is set aside' do
    ran(crawl: { 'fetched' => 12_000, 'expected' => 25_000, 'short' => ['Seafood'], 'failed' => [],
                 'capped' => ['Supplies'], 'capped_fetched' => 10_000, 'capped_expected' => 19_000 })
    read_today(on_list)

    expect(problems.join).to include('crawl came up short (2000 of 6000', 'short: Seafood')
  end

  # US Foods, Oct 20 2026: 612 of 800 read, but 88 were discontinued and 100
  # had no inventory block, so every item it could read was read.
  describe 'items on lists that can never be read' do
    it 'leaves discontinued items out of the coverage check' do
      on_list.last.update!(discontinued: true)
      ran
      read_today(on_list.first(3))

      expect(problems).to eq([])
      expect(row[:in_use_total]).to eq(3)
    end

    it 'leaves out items the supplier sent no stock for this morning, and shows how many' do
      ran(no_data: [on_list.last])
      read_today(on_list.first(3))

      expect(problems).to eq([])
      expect(row[:in_use_no_data]).to eq(1)
    end

    it 'still flags a real gap among the items it could read' do
      ran(no_data: [on_list.last])
      read_today(on_list.first(1))

      expect(problems).to include('only 1 of 3 items on lists got a stock reading (33%)')
    end

    it 'ignores no-stock items from an older run' do
      ran(at: 1.day.ago, no_data: [on_list.last])

      expect(row[:in_use_no_data]).to eq(0)
    end

    it 'flags a supplier that suddenly sends no stock for most items on lists' do
      more = Array.new(16) do |i|
        create(:supplier_product, supplier: supplier, supplier_sku: "M#{i}").tap do |sp|
          create(:supplier_list_item, supplier_list: list, supplier_product: sp, sku: "M#{i}", name: "More #{i}")
        end
      end
      ran(no_data: more.first(12))
      read_today(on_list + more.last(4))

      expect(problems.join).to include('the supplier sent no stock for 12 of 20 items on lists (60%', 'stock reader may have broken')
    end
  end

  it 'flags run errors' do
    ran(errors: ['Scraping failed: Net::ReadTimeout'])
    read_today(on_list)

    expect(problems.join).to include('run errors: Scraping failed: Net::ReadTimeout')
  end

  it 'flags low coverage of the items on lists' do
    ran
    read_today(on_list.first(2))

    expect(problems).to include('only 2 of 4 items on lists got a stock reading (50%)')
  end

  it 'ignores a supplier switched off' do
    supplier.update!(morning_stock_mode: 'off')

    expect(problems).to eq([])
  end

  it 'sends nothing when all is well' do
    ran
    read_today(on_list)

    expect { described_class.perform_now }.not_to change { ActionMailer::Base.deliveries.count }
  end

  it 'emails the super admin once a day when there is a problem' do
    ran(at: 1.day.ago)
    allow(Rails.cache).to receive(:read).and_return(nil, true)
    allow(Rails.cache).to receive(:write)

    expect { described_class.perform_now }.to change { ActionMailer::Base.deliveries.count }.by(1)
    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq([admin.email])
    expect(mail.subject).to include("Morning stock check: problems at Chef's Warehouse")

    expect { described_class.perform_now }.not_to change { ActionMailer::Base.deliveries.count }
  end
end
