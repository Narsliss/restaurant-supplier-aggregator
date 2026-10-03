require 'rails_helper'

RSpec.describe Orders::SupplierExceptionChecker do
  let(:user) { create(:user, :with_organization) }
  let(:usf) { Supplier.find_by(code: 'usfoods') || create(:supplier, code: 'usfoods') }
  let(:vinegar) { create(:supplier_product, supplier: usf, supplier_sku: '4336327', supplier_name: 'Vinegar, Champagne') }
  let(:order) do
    create(:order, user: user, supplier: usf, organization: user.current_organization, status: 'submitted',
                   confirmation_number: '1a33fcdd-83da-4bdb-973d-c4051e7e2e3c', delivery_date: Date.new(2026, 9, 28)).tap do |o|
      create(:order_item, order: o, supplier_product: vinegar)
    end
  end
  let(:scraper) { double('UsFoodsScraper') }
  let(:remote) do
    { 'orderStatus' => 'TANDEM_DELETED', 'orderItems' => [
      { 'productNumber' => 4336327, 'unitsOrdered' => 1, 'unitsReserved' => 0 },
      # a line a chef added on US Foods' own site — not on our order
      { 'productNumber' => 5555555, 'unitsOrdered' => 2, 'unitsReserved' => 0 }
    ] }
  end

  before do
    allow(Suppliers::OrderCredential).to receive(:scope).and_return(double(take: build_stubbed(:supplier_credential)))
    allow(usf).to receive(:scraper_klass).and_return(double(new: scraper))
    allow(order).to receive(:supplier).and_return(usf)
    switcher = double
    allow(switcher).to receive(:with_restaurant) { |&blk| blk.call }
    allow(Suppliers::RestaurantSwitcher).to receive(:new).and_return(switcher)
  end

  it 'looks the order up by id, delivery date and our items, and keeps only our lines' do
    expect(scraper).to receive(:fetch_submitted_order)
      .with('1a33fcdd-83da-4bdb-973d-c4051e7e2e3c', delivery_date: Date.new(2026, 9, 28), skus: ['4336327'])
      .and_return(remote)

    exceptions = described_class.new(order).check!

    expect(exceptions).to contain_exactly(hash_including(sku: '4336327', type: 'out_of_stock', name: 'Vinegar, Champagne'))
    expect(order.reload.supplier_exceptions).to contain_exactly(hash_including('sku' => '4336327'))
    expect(order.exceptions_checked_at).to be_present
  end

  it 'records nothing when US Foods no longer has the order' do
    allow(scraper).to receive(:fetch_submitted_order).and_return(nil)

    expect(described_class.new(order).check!).to be_nil
    expect(order.reload.exceptions_checked_at).to be_nil
  end
end
