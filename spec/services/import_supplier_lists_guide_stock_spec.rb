require 'rails_helper'

# docs/fix-morning-sync-at-scale.md: Sysco's 8 AM sync no longer re-imports
# the whole catalog for every login. Its guide carries prices but no stock,
# so the guide sync reads stock for the guide's items by item number.
RSpec.describe ImportSupplierListsService, 'guide stock' do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:supplier) { create(:supplier, morning_stock_mode: 'live') }
  let(:owner) { create(:user, current_organization: organization) }
  let(:credential) do
    create(:supplier_credential, user: owner, supplier: supplier, organization_id: organization.id, location_id: location.id)
  end
  let!(:butter) { create(:supplier_product, supplier: supplier, supplier_sku: 'B1', in_stock: true) }
  let!(:cream) { create(:supplier_product, supplier: supplier, supplier_sku: 'C1', in_stock: true) }
  let(:guide) do
    [{ remote_id: 'G-1', name: 'Order Guide',
       items: [{ sku: 'B1', name: 'Butter', price: 50.0, pack_size: '36/1 LB' },
               { sku: 'C1', name: 'Cream', price: 30.0, pack_size: '12/1 QT' }] }]
  end
  let(:scraper) { double('Sysco', scrape_lists: guide, crawl_stats: nil) }

  before do
    allow(SeedOrderListsService).to receive(:new).and_return(double(call: nil))
    allow(SyncNewProductsJob).to receive(:perform_later)
  end

  def sync(with: scraper)
    described_class.new(credential).call(scraper: with)
  end

  it "reads stock for the guide's items after syncing the guide" do
    allow(scraper).to receive(:live_stock_for).with(match_array(%w[B1 C1]))
                                               .and_return('B1' => [true, '"S" S'], 'C1' => [true, '"S" S'])

    result = sync

    expect(result[:lists_synced]).to eq(1)
    expect(butter.reload.stock_checked_at).to be_within(1.minute).of(Time.current)
    expect(cream.reload.stock_signal).to eq('"S" S')
  end

  # Sysco's guide says nothing about stock, so the guide sync stamps its items
  # "guide:in". The supplier's real reading has to be what stays.
  it "keeps the supplier's real reading over the guide's assumed in-stock" do
    allow(scraper).to receive(:live_stock_for).and_return('B1' => [false, '"O" S'], 'C1' => [true, '"S" S'])

    sync

    expect(butter.reload).to have_attributes(stock_signal: '"O" S', stock_source: 'catalog')
  end

  it 'still syncs the guide when the stock lookup fails' do
    allow(scraper).to receive(:live_stock_for).and_raise(StandardError, 'HTTP 429 for SearchProducts')

    result = sync

    expect(result[:lists_synced]).to eq(1)
    expect(result[:errors].join).to include('HTTP 429')
  end

  it 'changes nothing for suppliers without an item-number stock lookup (their guide says)' do
    plain = double('Scraper', scrape_lists: guide)

    sync(with: plain)

    expect(butter.reload).to have_attributes(stock_signal: 'guide:in', stock_source: 'guide')
  end
end
