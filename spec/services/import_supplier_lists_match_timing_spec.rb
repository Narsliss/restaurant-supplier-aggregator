require "rails_helper"

# Race found live on Sep 27 2026 (Performance reconnect at alfios): a new guide
# list is attached to its restaurant's matched list the moment it's saved, and
# matching used to start right then — before the guide's items finished
# importing — so it matched a partial guide and stranded the rest. Matching now
# starts once the import has finished.
RSpec.describe ImportSupplierListsService, "matching a newly connected guide" do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let!(:matched_list) do
    AggregatedList.find_by(location_id: location.id, list_type: %w[master matched]) ||
      create(:aggregated_list, organization: organization, location_id: location.id)
  end
  let(:supplier) { create(:supplier) }
  let(:owner) { create(:user, current_organization: organization) }
  let(:credential) do
    create(:supplier_credential, user: owner, supplier: supplier, organization_id: organization.id, location_id: location.id)
  end
  let(:guide) do
    [{ remote_id: "OG-1", name: "Order Guide",
       items: (1..3).map { |i| { sku: "SKU#{i}", name: "Item #{i}", price: 10.0 + i, pack_size: "1 CS" } } }]
  end
  let(:scraper) { double("Scraper", scrape_lists: guide) }

  before { allow(SeedOrderListsService).to receive(:new).and_return(double(call: nil)) }

  def import
    described_class.new(credential).call(scraper: scraper)
  end

  it "starts matching once, after every guide item is in" do
    items_when_matching_started = nil
    allow(SyncNewProductsJob).to receive(:perform_later) do |list_id|
      expect(list_id).to eq(matched_list.id)
      items_when_matching_started = SupplierList.find_by!(remote_list_id: "OG-1").supplier_list_items.count
    end

    import

    expect(SyncNewProductsJob).to have_received(:perform_later).once
    expect(items_when_matching_started).to eq(3)
  end

  it "still attaches the new guide to the matched list when it's created" do
    allow(SyncNewProductsJob).to receive(:perform_later)

    import

    expect(matched_list.reload.supplier_lists.pluck(:remote_list_id)).to include("OG-1")
  end

  it "doesn't start matching from list creation itself (the items aren't there yet)" do
    expect do
      create(:supplier_list, supplier: supplier, organization: organization, location: location)
    end.not_to have_enqueued_job(SyncNewProductsJob)
  end

  it "doesn't re-start matching on a routine re-sync of an existing guide" do
    allow(SyncNewProductsJob).to receive(:perform_later)
    import

    import

    expect(SyncNewProductsJob).to have_received(:perform_later).once
  end
end
