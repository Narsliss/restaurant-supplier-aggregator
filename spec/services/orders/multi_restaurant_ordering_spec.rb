require "rails_helper"

# ORDERING SAFETY — an owner's one supplier login can order for several of
# their restaurants. An order for Noche must go out through a connection that
# serves Noche, with the supplier switched to Noche and CONFIRMED before any
# cart is touched; a failed confirmation must stop the order untouched.
# Everyone without restaurant matches must get exactly the old behaviour.
RSpec.describe "Ordering for one of several restaurants on one login" do
  let(:owner) { create(:user, :with_organization) }
  let(:org) { owner.current_organization }
  let(:alfios) { create(:location, organization: org, user: owner, name: "Alfios") }
  let(:noche) { create(:location, organization: org, user: owner, name: "Noche") }
  let(:supplier) { Supplier.find_by(code: "usfoods") || create(:supplier, name: "US Foods", code: "usfoods") }
  let!(:credential) do
    create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id,
                                 location_id: alfios.id, status: "active")
  end
  let(:api) { FakeRestaurantApi.new(current: "80998842") }
  let(:scraper) do
    s = instance_double("FakeScraper", clear_cart: nil, add_to_cart: { added: [], failed: [] },
                                       verify_cart_matches!: true, close_order_browser!: nil,
                                       checkout: { dry_run: true, total: 25.0, confirmation_number: nil,
                                                   delivery_date: nil, cart_items: [] })
    allow(s).to receive(:api_client).and_return(api)
    s
  end
  let(:order) do
    create(:order, user: owner, supplier: supplier, organization: org, location: noche).tap do |o|
      create(:order_item, order: o, supplier_product: create(:supplier_product, supplier: supplier), quantity: 1, unit_price: 10)
    end
  end

  before do
    klass = double("ScraperClass", new: scraper)
    allow(supplier).to receive(:scraper_klass).and_return(klass)
    allow(order).to receive(:supplier).and_return(supplier)
    allow_any_instance_of(Orders::OrderValidationService).to receive(:validate!).and_return({ warnings: [], errors: [] })
  end

  def place
    Orders::OrderPlacementService.new(order).place_order(skip_pre_validation: true)
  end

  context "with the owner's login matched to both restaurants" do
    before do
      credential.restaurants.create!(location: alfios, supplier_account_id: "80998842")
      credential.restaurants.create!(location: noche, supplier_account_id: "31718356")
    end

    it "switches the supplier to Noche before touching the cart, then goes back home" do
      current_when_cart_cleared = nil
      allow(scraper).to receive(:clear_cart) { current_when_cart_cleared = api.current }

      result = place

      expect(result[:success]).to be(true)
      expect(current_when_cart_cleared).to eq("31718356")
      expect(api.current).to eq("80998842")
    end

    it "fails the order untouched when the supplier did not really switch" do
      api.ignore_switch = true
      expect(scraper).not_to receive(:clear_cart)
      expect(scraper).not_to receive(:add_to_cart)
      expect(scraper).not_to receive(:checkout)

      place

      expect(order.reload.status).to eq("failed")
    end

    it "refuses a restaurant the login is not matched to" do
      dor = create(:location, organization: org, user: owner, name: "D'oro")
      order.update!(location: dor)
      expect(scraper).not_to receive(:add_to_cart)

      expect { place }.to raise_error(Orders::OrderValidationService::ValidationError)
      expect(order.reload.status).to eq("failed")
    end
  end

  context "without restaurant matches (every chef, every single-restaurant owner)" do
    it "uses the same connection as before and never switches" do
      result = place

      expect(result[:success]).to be(true)
      expect(api.switches).to be_empty
    end
  end

  # Performance: no picker — a separate login per restaurant, all three under
  # the owner's one EnPlace account, each attached to its restaurant.
  context "an owner with a separate login per restaurant" do
    let(:doro) { create(:location, organization: org, user: owner, name: "D'oro") }
    let!(:noche_login) do
      create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id,
                                   location_id: noche.id, status: "active")
    end
    let!(:doro_login) do
      create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id,
                                   location_id: doro.id, status: "active")
    end
    let(:scraper_class) { double("ScraperClass", new: scraper) }

    before do
      allow(supplier).to receive(:scraper_klass).and_return(scraper_class)
      order.update!(location: doro)
    end

    it "sends a D'oro order through the D'oro login" do
      result = place

      expect(result[:success]).to be(true)
      expect(scraper_class).to have_received(:new).with(doro_login)
      expect(scraper_class).not_to have_received(:new).with(credential)
    end

    it "fails the D'oro order rather than use the alfios login when D'oro's login is not active" do
      doro_login.update!(status: "expired")
      noche_login.update!(status: "expired")

      expect { place }.to raise_error(Orders::OrderValidationService::ValidationError, /No active credentials/)

      expect(scraper_class).not_to have_received(:new)
      expect(order.reload.status).to eq("failed")
    end

    it "puts only the D'oro login on hold when Performance reports D'oro's account on hold" do
      allow(scraper).to receive(:add_to_cart).and_raise(Scrapers::BaseScraper::AccountHoldError, "Account on credit hold")

      place

      expect(doro_login.reload).to have_attributes(status: "hold", account_on_hold: true)
      expect([credential.reload.status, noche_login.reload.status]).to eq(%w[active active])
      expect(order.reload.status).to eq("failed")
    end

    it "runs the pre-order check against the order's restaurant" do
      expect(Orders::PreOrderValidationService).to receive(:new)
        .with(hash_including(location_id: doro.id)).and_call_original
      allow_any_instance_of(Orders::PreOrderValidationService).to receive(:validate!).and_return(valid: true, errors: [], warnings: [], price_changes: [])

      Orders::OrderPlacementService.new(order).place_order
    end

    it "fails loudly for a restaurant with no login of its own" do
      doro_login.destroy!
      expect(scraper).not_to receive(:add_to_cart)

      expect { place }.to raise_error(Orders::OrderValidationService::ValidationError, /No active credentials/)
      expect(scraper_class).not_to have_received(:new)
      expect(order.reload.status).to eq("failed")
    end
  end

  describe Suppliers::OrderCredential do
    it "picks only a connection serving the order's restaurant once matches exist" do
      noche_cred = create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id,
                                                location_id: noche.id, status: "active")
      credential.restaurants.create!(location: alfios, supplier_account_id: "80998842")

      expect(described_class.scope(order).to_a).to eq([noche_cred])
    end

    it "is the old lookup for a user with no matches" do
      expect(described_class.scope(order).take).to eq(credential)
    end
  end
end
