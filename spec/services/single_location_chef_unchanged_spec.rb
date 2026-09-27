require "rails_helper"

# Multi-location switching (branch multi-location-switching) is for owners and
# managers whose one supplier login orders for several restaurants. A chef with
# one restaurant must see NO difference anywhere it touches: which login places
# an order, whether anything is switched, the builder's fallback suppliers,
# list syncs, PPO's restaurant, and connect-time checks.
RSpec.describe "A single-location chef is unaffected by multi-location switching" do
  let(:owner) { create(:user, :with_organization) }
  let(:org) { owner.current_organization }
  let(:kitchen) { create(:location, organization: org, user: owner, name: "Noche") }
  let(:chef) do
    user = create(:user, current_organization: org)
    create(:membership, user: user, organization: org, role: "chef", active: true)
      .membership_locations.create!(location: kitchen)
    user
  end
  let(:supplier) { Supplier.find_by(code: "usfoods") || create(:supplier, name: "US Foods", code: "usfoods") }
  let!(:credential) do
    create(:supplier_credential, user: chef, supplier: supplier, organization_id: org.id,
                                 location_id: kitchen.id, status: "active")
  end
  let(:order) do
    create(:order, user: chef, supplier: supplier, organization: org, location: kitchen).tap do |o|
      create(:order_item, order: o, supplier_product: create(:supplier_product, supplier: supplier), quantity: 1, unit_price: 10)
    end
  end

  describe "placing an order" do
    # No api_client stub: asking the scraper for one would fail the example.
    let(:scraper) do
      double("Scraper", clear_cart: nil, add_to_cart: { added: [], failed: [] }, verify_cart_matches!: true,
                        close_order_browser!: nil,
                        checkout: { dry_run: true, total: 25.0, confirmation_number: nil, delivery_date: nil, cart_items: [] })
    end

    let(:scraper_class) { double("ScraperClass", new: scraper) }

    before do
      allow(supplier).to receive(:scraper_klass).and_return(scraper_class)
      allow(order).to receive(:supplier).and_return(supplier)
      allow_any_instance_of(Orders::OrderValidationService).to receive(:validate!).and_return({ warnings: [], errors: [] })
    end

    it "goes out through the chef's own login with nothing switched or even looked up at the supplier" do
      expect(SupplierCredential.connection).not_to receive(:execute).with(/pg_advisory/)

      result = Orders::OrderPlacementService.new(order).place_order(skip_pre_validation: true)

      expect(result[:success]).to be(true)
      expect(scraper_class).to have_received(:new).with(credential).at_least(:once)
    end
  end

  describe "which login an order uses" do
    it "is the old lookup, even when the login is recorded on another restaurant" do
      credential.update!(location: create(:location, organization: org, user: owner))

      expect(Suppliers::OrderCredential.scope(order).take).to eq(credential)
      expect(Suppliers::OrderCredential.scope(order, statuses: nil).take).to eq(credential)
    end
  end

  describe "the order builder's fallback suppliers" do
    it "is the chef's full list, even when the login is recorded on another restaurant" do
      credential.update!(location: create(:location, organization: org, user: owner))

      ids = Orders::AggregatedListOrderService.orderable_supplier_ids(chef, location: kitchen)

      expect(ids).to include(supplier.id)
    end
  end

  describe "the restaurant switcher" do
    it "passes straight through without building the supplier API client" do
      scraper = double("Scraper")
      expect(scraper).not_to receive(:api_client)
      ran = false

      Suppliers::RestaurantSwitcher.new(credential, scraper).with_restaurant(kitchen.id) { ran = true }

      expect(ran).to be(true)
    end
  end

  describe "list sync" do
    it "files the guide under the chef's restaurant, owned by the chef's login, and still seeds" do
      scraper = double("Scraper", scrape_lists: [{ remote_id: "OG-1", name: "Guide",
                                                   items: [{ sku: "A1", name: "Item", price: 5.0, pack_size: "1 CS" }] }])
      expect(scraper).not_to receive(:api_client)
      seeder = instance_double(SeedOrderListsService, call: nil)
      expect(SeedOrderListsService).to receive(:new).with(credential).and_return(seeder)

      ImportSupplierListsService.new(credential).call(scraper: scraper)

      list = SupplierList.find_by!(remote_list_id: "OG-1")
      expect([list.location_id, list.supplier_credential_id]).to eq([kitchen.id, credential.id])
    end
  end

  describe "connecting a supplier" do
    it "never asks the supplier for a restaurant list for a chef" do
      expect(Suppliers::RestaurantSwitcher).not_to receive(:list_restaurants)

      Suppliers::RestaurantMatching.record_count(credential)
    end

    it "never asks for a one-restaurant owner either" do
      own = create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id)
      org.locations.where.not(id: org.locations.first.id).destroy_all
      expect(Suppliers::RestaurantSwitcher).not_to receive(:list_restaurants)

      Suppliers::RestaurantMatching.record_count(own)
    end
  end

  describe "PPO with one restaurant on the login" do
    it "uses that restaurant, exactly as before" do
      cred = create(:supplier_credential, session_data: { "api_tokens" => { "id_token" => "tok" } }.to_json)
      api = Scrapers::PremiereProduceOneApi.new(cred)
      allow(api).to receive(:graphql).and_return("employee_chats" => [
        { "chat_uuid" => "c1", "restaurant_uuid" => "r1", "supplier_uuid" => "s", "business_organization_uuid" => "o" }
      ])

      api.restore_session

      expect([api.restaurant_uuid, api.chat_uuid]).to eq(%w[r1 c1])
      expect(JSON.parse(cred.reload.session_data).dig("api_tokens", "restaurant_uuid")).to eq("r1").or be_nil
    end
  end
end
