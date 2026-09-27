require "rails_helper"

# A multi-restaurant login syncs each matched restaurant into its own location
# — switching first — without taking over a chef's own lists, without tripping
# over repeated remote ids, and without judging other restaurants' lists.
RSpec.describe ImportSupplierListsService, "multi-restaurant login" do
  let(:owner) { create(:user, :with_organization) }
  let(:org) { owner.current_organization }
  let(:alfios) { create(:location, organization: org, user: owner, name: "Alfios") }
  let(:noche) { create(:location, organization: org, user: owner, name: "Noche") }
  let(:supplier) { Supplier.find_by(code: "whatchefswant") || create(:supplier, name: "What Chefs Want", code: "whatchefswant") }
  let(:credential) do
    create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id, location_id: alfios.id)
  end
  let(:api) { FakeRestaurantApi.new(current: "342485441") }
  let(:guides) do
    {
      "342485441" => [{ remote_id: "order-guide", name: "Alfios guide",
                        items: [{ sku: "A1", name: "Alfios item", price: 10.0, pack_size: "1 CS" }] }],
      "499909181" => [{ remote_id: "order-guide", name: "Noche guide",
                        items: [{ sku: "N1", name: "Noche item", price: 12.0, pack_size: "1 CS" }] }]
    }
  end
  let(:scraper) do
    fake = Object.new
    a = api
    g = guides
    fake.define_singleton_method(:api_client) { a }
    fake.define_singleton_method(:scrape_lists) { g.fetch(a.current) }
    fake
  end

  before do
    credential.restaurants.create!(location: alfios, supplier_account_id: "342485441")
    credential.restaurants.create!(location: noche, supplier_account_id: "499909181")
    allow(SeedOrderListsService).to receive(:new).and_call_original
  end

  def sync
    described_class.new(credential).call(scraper: scraper)
  end

  it "files each restaurant's guide under its own location" do
    sync

    lists = SupplierList.where(supplier: supplier, organization: org)
    expect(lists.find_by!(location_id: alfios.id).supplier_list_items.pluck(:sku)).to eq(["A1"])
    expect(lists.find_by!(location_id: noche.id).supplier_list_items.pluck(:sku)).to eq(["N1"])
    expect(api.current).to eq("342485441")
  end

  it "owns its home list but does not claim a second list with the same remote id" do
    sync

    expect(SupplierList.find_by!(location_id: alfios.id).supplier_credential_id).to eq(credential.id)
    expect(SupplierList.find_by!(location_id: noche.id).supplier_credential_id).to be_nil
  end

  it "never takes over a chef's own list for that restaurant" do
    chef = create(:user, current_organization: org)
    create(:membership, user: chef, organization: org, role: "chef", active: true)
    chef_cred = create(:supplier_credential, user: chef, supplier: supplier, organization_id: org.id, location_id: noche.id)
    chef_list = SupplierList.create!(supplier: supplier, organization: org, location_id: noche.id,
                                     remote_list_id: "order-guide", name: "Noche guide", supplier_credential: chef_cred)

    sync

    expect(chef_list.reload.supplier_credential_id).to eq(chef_cred.id)
    expect(chef_list.supplier_list_items.pluck(:sku)).to eq(["N1"])
  end

  it "only judges the synced restaurant's lists when marking lists gone" do
    alfios_extra = SupplierList.create!(supplier: supplier, organization: org, location_id: alfios.id,
                                        remote_list_id: "alfios-only", name: "Alfios extra", sync_status: "synced")
    guides["342485441"] << { remote_id: "alfios-only", name: "Alfios extra", items: [] }

    sync

    expect(alfios_extra.reload.sync_status).not_to eq("failed")
  end

  it "seeds order lists only for the connection's home restaurant" do
    sync

    expect(SeedOrderListsService).to have_received(:new).once
  end

  it "keeps syncing the other restaurants when one will not switch" do
    guides["499909181"] = [] # never reached
    allow(api).to receive(:switch_company!).and_wrap_original do |m, id|
      id.to_s == "499909181" ? true : m.call(id) # Noche silently refuses
    end

    result = sync

    expect(SupplierList.where(location_id: alfios.id)).to exist
    expect(SupplierList.where(location_id: noche.id)).not_to exist
    expect(result[:errors].join).to include("Noche")
  end
end
