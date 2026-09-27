require "rails_helper"

# The nightly Sysco run: catalog search, known-SKU price refresh, then the
# pack-size heal (Sep 27 2026), then order guides. The refresh keeps the long
# tail priced but can't see packs, so the heal has to run every night after it.
RSpec.describe SyscoCombinedImportJob do
  let(:sysco) { Supplier.find_by(code: "sysco") || create(:supplier, name: "Sysco", code: "sysco") }
  let(:credential) { create(:supplier_credential, supplier: sysco, status: "active") }
  let(:scraper) { double("scraper", fetch_available_delivery_days: []) }
  let(:products_service) { instance_double(ImportSupplierProductsService) }
  let(:lists_service) { instance_double(ImportSupplierListsService) }
  let(:calls) { [] }

  before do
    allow_any_instance_of(Supplier).to receive(:scraper_klass).and_return(double(new: scraper))
    allow(scraper).to receive(:send).with(:ensure_api_session!)
    allow(ImportSupplierProductsService).to receive(:new).and_return(products_service)
    allow(ImportSupplierListsService).to receive(:new).and_return(lists_service)
    allow(products_service).to receive(:release_import_indexes!)
    allow(products_service).to receive(:import_catalog) { calls << :catalog; { imported: 0, updated: 0 } }
    allow(products_service).to receive(:refresh_known_products) { calls << :refresh; { updated: 0, missed: 0 } }
    allow(lists_service).to receive(:call) { calls << :lists; {} }
  end

  it "heals unit-less packs after the price refresh and before the order guides" do
    allow(products_service).to receive(:heal_unitless_pack_sizes) { calls << :heal; { checked: 2, healed: 1 } }

    described_class.perform_now(credential.id)

    expect(calls).to eq(%i[catalog refresh heal lists])
    expect(products_service).to have_received(:heal_unitless_pack_sizes).with(scraper: scraper)
  end

  it "still imports the order guides when the heal fails" do
    allow(products_service).to receive(:heal_unitless_pack_sizes).and_raise(StandardError, "search down")

    described_class.perform_now(credential.id)

    expect(calls).to eq(%i[catalog refresh lists])
    expect(credential.reload.status).to eq("active")
  end
end
