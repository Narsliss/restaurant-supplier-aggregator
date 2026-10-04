require 'rails_helper'

# CW catalog import stored no prices (since Mar 23) and catalog search hides
# unpriced items — 13,444 of 15,624 CW products were invisible. Shapes below
# match live /product/prices answers (Oct 3 2026): a CS request carries the
# piece price as its secondary price; 133002 items don't price under 800001.
RSpec.describe ChefsWarehouseCatalogPricingJob, type: :job do
  let(:supplier) { Supplier.find_by(code: 'chefswarehouse') || create(:supplier, code: 'chefswarehouse', name: "Chef's Warehouse") }
  let!(:credential) { create(:supplier_credential, supplier: supplier, status: 'active') }
  let(:api) { instance_double(Scrapers::ChefsWarehouseApi, ensure_session!: true) }

  let!(:lemon_juice) { create(:supplier_product, supplier: supplier, supplier_sku: 'QG80027A', supplier_name: 'Juice Lemon Real', pack_size: '6x32 OZ', current_price: nil) }
  let!(:liners) { create(:supplier_product, supplier: supplier, supplier_sku: 'RWP1178B', supplier_name: 'Trash Liners', pack_size: '1x100 CT', current_price: nil) }
  let!(:cheese) { create(:supplier_product, supplier: supplier, supplier_sku: 'QG9791', supplier_name: 'Parmesan', pack_size: '1x1 LB Piece', current_price: nil) }
  let!(:oil) { create(:supplier_product, supplier: supplier, supplier_sku: '1118295', supplier_name: 'Oil', pack_size: '2x2 LB BC', current_price: nil) }
  let!(:gone) { create(:supplier_product, supplier: supplier, supplier_sku: 'NOPE1', supplier_name: 'Gone', current_price: nil) }
  let!(:already) { create(:supplier_product, supplier: supplier, supplier_sku: 'GO135', supplier_name: 'Olive Oil', current_price: 134.04) }

  def price(code, primary, secondary = nil, restricted: false)
    { variant_code: code, primary_price: primary, secondary_price: secondary, restricted: restricted }
  end

  before do
    allow_any_instance_of(Scrapers::ChefsWarehouseScraper).to receive(:api_client).and_return(api)
    allow(api).to receive(:fetch_prices).and_return([
      price('JDE_QG80027A-800001', 45.40),
      price('JDE_RWP1178B-133002', 92.34),
      price('JDE_QG9791-800001', 11.74, 11.74),
      price('JDE_1118295-800001', 34.36, 18.90)
    ])
  end

  it 'prices unpriced catalog items, under whichever business unit CW prices them' do
    summary = described_class.perform_now

    expect(lemon_juice.reload.current_price).to eq(45.40)
    expect(liners.reload.current_price).to eq(92.34)
    expect(summary).to include(checked: 5, saved: 4, not_priced: 1, bu_800001: 3, bu_133002: 1)
    expect(gone.reload.current_price).to be_nil
  end

  it "applies order-guide pricing rules for pieces: 'Piece' packs use the piece price; piece_price only when it differs" do
    described_class.perform_now

    expect(cheese.reload).to have_attributes(current_price: 11.74, piece_price: nil)
    expect(oil.reload).to have_attributes(current_price: 34.36, piece_price: 18.90, piece_pack_size: 'PC')
  end

  it 'leaves already-priced items alone by default, and re-prices them with scope: all' do
    described_class.perform_now
    expect(api).to have_received(:fetch_prices).at_least(:once)
    expect(already.reload.current_price).to eq(134.04)

    allow(api).to receive(:fetch_prices).and_return([price('JDE_GO135-800001', 140.00)])
    described_class.perform_now('all')
    expect(already.reload).to have_attributes(current_price: 140.00, previous_price: 134.04)
  end

  it 'saves nothing on a dry run but reports what it would do' do
    summary = described_class.perform_now(dry_run: true)

    expect(summary).to include(checked: 5, not_priced: 1, dry_run: true)
    expect(summary[:saved]).to be_nil.or eq(0)
    expect(lemon_juice.reload.current_price).to be_nil
  end

  it 'honours a limit for a small first run' do
    expect(described_class.perform_now(limit: 2)[:checked]).to eq(2)
  end

  it 'treats a restricted price as not orderable' do
    allow(api).to receive(:fetch_prices).and_return([price('JDE_QG80027A-800001', 45.40, restricted: true)])

    described_class.perform_now

    expect(lemon_juice.reload.current_price).to be_nil
  end

  it 'keeps going when a batch fails' do
    calls = 0
    allow(api).to receive(:fetch_prices) do
      calls += 1
      raise Net::ReadTimeout if calls == 1

      [price('JDE_QG80027A-800001', 45.40)]
    end
    stub_const("#{described_class}::BATCH", 2)

    summary = described_class.perform_now

    expect(summary[:batch_errors]).to eq(1)
    expect(calls).to be > 1
  end

  describe 'the production schedule' do
    let(:recurring) { YAML.load_file(Rails.root.join('config/recurring.yml'))['production'] }

    %w[cw_catalog_pricing_new cw_catalog_pricing_refresh].each do |key|
      it "#{key} is a valid recurring task the job accepts" do
        config = recurring.fetch(key)
        task = SolidQueue::RecurringTask.from_configuration(key, **config.symbolize_keys)
        expect(task).to be_valid
        expect(config['class']).to eq(described_class.name)

        # recurring.yml passes args by position — run exactly that
        expect { described_class.perform_now(*config['args']) }.not_to raise_error
      end
    end
  end

  it 'never touches stock flags' do
    lemon_juice.update!(in_stock: false)

    described_class.perform_now

    expect(lemon_juice.reload.in_stock).to be(false)
  end
end
