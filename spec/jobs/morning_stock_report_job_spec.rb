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

  def ran(at: Time.current, errors: [], crawl: { 'fetched' => 100, 'expected' => 100, 'short' => [], 'failed' => [] })
    supplier.update!(last_stock_run: { 'at' => at.iso8601, 'kind' => 'catalog', 'errors' => errors, 'crawl' => crawl })
  end

  def read_today(products)
    products.each { |sp| sp.update!(stock_checked_at: Time.current) }
  end

  def problems
    described_class.build_report.find { |r| r[:supplier] == supplier }[:problems]
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
