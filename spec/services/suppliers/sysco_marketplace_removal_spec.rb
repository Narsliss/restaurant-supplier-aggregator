require 'rails_helper'

# Carmin (Sep 27 2026): Sysco Marketplace / Specialty items come off EnPlace —
# catalog, ordering, matched lists and mirrored order guides.
RSpec.describe Suppliers::SyscoMarketplaceRemoval do
  let(:sysco) { Supplier.find_by(code: 'sysco') || create(:supplier, code: 'sysco', name: 'Sysco') }
  let(:other_supplier) { create(:supplier, name: 'US Foods') }
  let(:credential) { create(:supplier_credential, supplier: sysco) }
  let(:scraper) { Scrapers::SyscoScraper.allocate }

  let(:org) { create(:organization) }
  let(:matched) { create(:aggregated_list, organization: org) }
  let(:guide) { create(:supplier_list, supplier: sysco, organization: org) }
  let(:other_guide) { create(:supplier_list, supplier: other_supplier, organization: org) }

  let!(:sugar) { create(:supplier_product, supplier: sysco, supplier_sku: '4279592', supplier_seller_id: 'USBL', supplier_seller_group: 'LOCAL_SALES') }
  let!(:pineapple) { create(:supplier_product, supplier: sysco, supplier_sku: '6081093', supplier_seller_id: '2011', supplier_seller_group: 'MARKETPLACE') }
  let!(:syrup) { create(:supplier_product, supplier: sysco, supplier_sku: '5899810', supplier_seller_id: 'SOTF', supplier_seller_group: 'SPECIALTY') }
  let!(:usf_pineapple) { create(:supplier_product, supplier: other_supplier, supplier_sku: 'U1') }

  let!(:sugar_item) { create(:supplier_list_item, supplier_list: guide, supplier_product: sugar, sku: '4279592') }
  let!(:pineapple_item) { create(:supplier_list_item, supplier_list: guide, supplier_product: pineapple, sku: '6081093') }
  let!(:syrup_item) { create(:supplier_list_item, supplier_list: guide, supplier_product: syrup, sku: '5899810') }
  let!(:usf_item) { create(:supplier_list_item, supplier_list: other_guide, supplier_product: usf_pineapple, sku: 'U1') }

  # Pineapple row: Sysco (Marketplace) + US Foods. Syrup row: Sysco Specialty only.
  let!(:pineapple_row) { create(:product_match, aggregated_list: matched, canonical_image_supplier_product_id: nil) }
  let!(:syrup_row) { create(:product_match, aggregated_list: matched) }
  let!(:sugar_row) { create(:product_match, aggregated_list: matched) }

  before do
    create(:product_match_item, product_match: pineapple_row, supplier_list_item: pineapple_item)
    create(:product_match_item, product_match: pineapple_row, supplier_list_item: usf_item)
    create(:product_match_item, product_match: syrup_row, supplier_list_item: syrup_item)
    create(:product_match_item, product_match: sugar_row, supplier_list_item: sugar_item)

    allow(scraper).to receive(:logger).and_return(Logger.new(nil))
    allow(scraper).to receive(:ensure_api_session!)
    allow(scraper).to receive(:load_api_tokens).and_return(site_id: '019', seller_id: 'USBL')
    allow(scraper).to receive(:discover_sellers).and_return({})
  end

  def run(dry_run:)
    described_class.new(credential, dry_run: dry_run, scraper: scraper).call
  end

  it 'reports what would go on a dry run and changes nothing' do
    report = run(dry_run: true)

    expect(report).to include(third_party_products: 2, matched_list_cells: 2, matched_rows_touched: 2, guide_items: 2)
    expect(report[:by_group]).to eq('MARKETPLACE' => 1, 'SPECIALTY' => 1)
    expect(ProductMatchItem.count).to eq(4)
    expect(pineapple.reload.discontinued).to be(false)
  end

  it 'removes Marketplace and Specialty items from matched lists, guides and the catalog' do
    report = run(dry_run: false)

    expect(report[:removal]).to include(removed_items: 2, guide_items: 2, products_discontinued: 2)
    # The pineapple row keeps its US Foods cell; the Specialty-only row is gone.
    expect(pineapple_row.reload.product_match_items.map(&:supplier_id)).to eq([other_supplier.id])
    expect(ProductMatch.exists?(syrup_row.id)).to be(false)
    expect(SupplierListItem.where(id: [pineapple_item.id, syrup_item.id])).to be_empty
    expect(pineapple.reload).to have_attributes(discontinued: true, in_stock: false)
    expect(MatchItemRemoval.where(cause: described_class::CAUSE).count).to eq(2)
  end

  it "leaves Sysco's own stock and other suppliers alone" do
    run(dry_run: false)

    expect(sugar.reload.discontinued).to be(false)
    expect(sugar_row.reload.product_match_items.count).to eq(1)
    expect(SupplierListItem.exists?(sugar_item.id)).to be(true)
    expect(SupplierListItem.exists?(usf_item.id)).to be(true)
  end

  it 'keeps a row a chef order list still uses, even if it empties' do
    order_list = OrderList.create!(user: create(:user), organization: org, name: 'Weekly')
    OrderListItem.create!(order_list: order_list, product_match: syrup_row, quantity: 1)

    run(dry_run: false)

    expect(ProductMatch.exists?(syrup_row.id)).to be(true)
    expect(syrup_row.reload.product_match_items).to be_empty
  end

  it 'counts a seller other than the account seller as third party when no group is stored' do
    pineapple.update!(supplier_seller_group: nil)

    expect(run(dry_run: true)[:third_party_products]).to eq(2)
  end

  it 'classifies Sysco products that have no seller group yet, uncapped' do
    sugar.update!(supplier_seller_group: nil)

    run(dry_run: true)

    expect(scraper).to have_received(:discover_sellers).with(['4279592'], limit: nil)
  end
end
