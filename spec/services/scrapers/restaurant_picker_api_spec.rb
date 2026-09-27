require "rails_helper"

# The supplier calls behind restaurant switching, as proven on production
# (docs/owner-multi-location-findings.md). Network is stubbed.
RSpec.describe "Supplier restaurant pickers" do
  let(:credential) { create(:supplier_credential) }

  describe Scrapers::UsFoodsApi do
    let(:api) { described_class.new(credential) }

    def jwt(claims)
      "h.#{Base64.urlsafe_encode64(claims.to_json).delete('=')}.s"
    end

    it "lists the login's restaurants from the customers endpoint" do
      allow(api).to receive(:get_customers).and_return([
        { "customerNumber" => 80998842, "divisionNumber" => 1103, "customerName" => "ALFIO'S BUON CIBO PNTO",
          "address1" => "2724 ERIE AVE", "city" => "CINCINNATI", "zip" => "452081234" },
        { "customerNumber" => 31718356, "divisionNumber" => 1103, "customerName" => "NOCHE PNTO",
          "address" => { "addressLine1" => "701 MADISON AVE", "city" => "COVINGTON", "zipCode" => "41011" } }
      ])

      expect(api.list_restaurants).to eq([
        { id: "80998842", name: "ALFIO'S BUON CIBO PNTO — CINCINNATI", street: "2724 ERIE AVE", city: "CINCINNATI",
          zip: "452081234", meta: { "division_number" => 1103 } },
        { id: "31718356", name: "NOCHE PNTO — COVINGTON", street: "701 MADISON AVE", city: "COVINGTON",
          zip: "41011", meta: { "division_number" => 1103 } }
      ])
    end

    it "switches by refreshing the token with the restaurant's customer number" do
      api.instance_variable_set(:@access_token, jwt("usf-claims" => { "customerNumber" => 80998842 }))
      api.instance_variable_set(:@token_expires_at, 1.hour.from_now)
      api.instance_variable_set(:@auth_context, { "customer_number" => 80998842, "division_number" => 1103, "department_number" => 0 })
      sent = nil
      allow(api).to receive(:refresh_access_token) do
        sent = api.instance_variable_get(:@auth_context).dup
        api.instance_variable_set(:@access_token, jwt("usf-claims" => { "customerNumber" => 31718356 }))
        true
      end

      api.switch_customer!("31718356", 1103)

      expect(sent).to include("customer_number" => 31718356, "division_number" => 1103, "department_number" => 0)
      expect(api.token_customer_number).to eq("31718356")
    end

    it "fails loudly when the token cannot be refreshed" do
      api.instance_variable_set(:@access_token, jwt({}))
      api.instance_variable_set(:@token_expires_at, 1.hour.from_now)
      allow(api).to receive(:refresh_access_token).and_return(false)

      expect { api.switch_customer!("31718356", 1103) }.to raise_error(Scrapers::BaseScraper::AuthenticationError)
    end

    it "reads nothing from a malformed token instead of guessing" do
      api.instance_variable_set(:@access_token, "not-a-jwt")

      expect(api.token_customer_number).to be_nil
    end
  end

  describe Scrapers::ChefsWarehouseApi do
    let(:api) { described_class.new(credential) }

    it "lists organizations as restaurants" do
      allow(api).to receive(:list_organizations).and_return([
        { "id" => "614969", "name" => "ALFIO'S", "isActive" => true },
        { "id" => "9508766", "name" => "NOCHE", "isActive" => false }
      ])

      expect(api.list_restaurants.map { |r| r[:id] }).to eq(%w[614969 9508766])
    end

    it "switches with the site's own organization/set call" do
      expect(api).to receive(:post_json).with("/web-api/organization/set?value=9508766", {})

      api.set_organization!("9508766")
    end

    it "confirms by ship-to, falling back to the organization id" do
      allow(api).to receive(:current_user).and_return({ "currentOrganizationId" => "9508766",
                                                        "currentOrganization" => { "shipTo" => "9508766", "shippingAddress1" => "" } })
      expect(api.current_ship_to).to eq("9508766")

      allow(api).to receive(:current_user).and_return({ "currentOrganizationId" => "614969", "currentOrganization" => {} })
      expect(api.current_ship_to).to eq("614969")
    end
  end

  describe Scrapers::WhatChefsWantApi do
    let(:api) { described_class.new(credential) }

    it "lists the current company plus additionalCompanies" do
      allow(api).to receive(:graphql_request).and_return(
        "data" => { "user" => {
          "company" => { "id" => "342485441", "name" => "Alfio's Buon Cibo",
                         "locations" => [{ "id" => "342485440", "address" => "2724 ERIE AVE", "city" => "CINCINNATI", "zip" => "45208" }] },
          "additionalCompanies" => [{ "id" => "499909181", "name" => "Noche Covington",
                                      "locations" => [{ "id" => "499909180", "address" => "701 MADISON AVE",
                                                        "city" => "COVINGTON", "zip" => "41011" }] }]
        } }
      )

      expect(api.list_restaurants).to eq([
        { id: "342485441", name: "Alfio's Buon Cibo", street: "2724 ERIE AVE", city: "CINCINNATI", zip: "45208",
          meta: { "location_ids" => ["342485440"] } },
        { id: "499909181", name: "Noche Covington", street: "701 MADISON AVE", city: "COVINGTON", zip: "41011",
          meta: { "location_ids" => ["499909180"] } }
      ])
    end

    it "switches via the site's link and re-reads the new company's location and order guide" do
      allow(api).to receive(:ensure_session!)
      api.instance_variable_set(:@cookies, { "session" => "x" })
      api.instance_variable_set(:@location_id, "342485440")
      http = instance_double(Net::HTTP)
      allow(api).to receive(:ensure_http).and_return(http)
      response = Net::HTTPTemporaryRedirect.new("1.1", "307", "Temporary Redirect")
      expect(http).to receive(:request) { |req| expect(req.path).to eq("/login/switchCompany/499909181"); response }
      expect(api).to receive(:discover_context) { api.instance_variable_set(:@location_id, "499909180"); true }

      api.switch_company!("499909181")

      expect(api.location_id).to eq("499909180")
    end

    it "raises when the switch is rejected" do
      allow(api).to receive(:ensure_session!)
      api.instance_variable_set(:@cookies, {})
      http = instance_double(Net::HTTP, request: Net::HTTPForbidden.new("1.1", "403", "Forbidden"))
      allow(api).to receive(:ensure_http).and_return(http)

      expect { api.switch_company!("499909181") }.to raise_error(Scrapers::BaseScraper::ScrapingError, /403/)
    end
  end

  describe Scrapers::PremiereProduceOneApi do
    # Alfio's PPO login as returned Sep 27 2026: one employee chat per restaurant.
    let(:alfios) { "a7b88739-85ae-438e-8820-35d530b794bc" }
    let(:doro) { "b2171ba1-5fd5-412c-9808-cb515494a3f5" }
    let(:chats) do
      [{ "chat_uuid" => "chat-alfios", "restaurant_uuid" => alfios, "supplier_uuid" => "sup",
         "business_organization_uuid" => "org", "restaurant_name" => "ALFIO'S BUON CIBO",
         "restaurant_account_id" => "ALFBUO", "restaurant_address" => "2724 Erie Ave, Cincinnati, OH 45208, USA" },
       { "chat_uuid" => "chat-doro", "restaurant_uuid" => doro, "supplier_uuid" => "sup",
         "business_organization_uuid" => "org", "restaurant_name" => "D'ORO RESTAURANT",
         "restaurant_account_id" => "DORO", "restaurant_address" => "Montgomery, OH 45242, USA" }]
    end
    let(:credential) do
      create(:supplier_credential, session_data: { "api_tokens" => { "id_token" => "tok", "restaurant_uuid" => alfios,
                                                                     "chat_uuid" => "chat-alfios" } }.to_json)
    end

    def client
      described_class.new(credential).tap do |api|
        allow(api).to receive(:graphql).and_return("employee_chats" => chats)
      end
    end

    it "lists the login's restaurants from its employee chats" do
      expect(client.list_restaurants).to eq([
        { id: alfios, name: "ALFIO'S BUON CIBO — Cincinnati", street: "2724 Erie Ave", city: "Cincinnati", zip: "45208",
          meta: { "account_id" => "ALFBUO", "chat_uuid" => "chat-alfios" } },
        # PPO gives D'oro no street — it can't be linked by address.
        { id: doro, name: "D'ORO RESTAURANT — Montgomery", street: nil, city: "Montgomery", zip: "45242",
          meta: { "account_id" => "DORO", "chat_uuid" => "chat-doro" } }
      ])
    end

    it "starts on the restaurant saved with the session, whatever order the chats come in" do
      chats.reverse!
      api = client
      api.restore_session

      expect(api.current_restaurant_uuid).to eq(alfios)
      expect(api.chat_uuid).to eq("chat-alfios")
    end

    it "switches by pinning the restaurant every call carries" do
      api = client
      api.restore_session

      api.select_restaurant!(doro)

      expect(api.current_restaurant_uuid).to eq(doro)
      expect(api.chat_uuid).to eq("chat-doro")
    end

    it "keeps a rebuilt client on the pinned restaurant (no silent drift home mid-order)" do
      client.tap(&:restore_session).select_restaurant!(doro)

      rebuilt = client
      rebuilt.restore_session

      expect(rebuilt.current_restaurant_uuid).to eq(doro)
    end

    it "saves the home restaurant with the session, never the pinned one" do
      api = client
      api.restore_session
      api.select_restaurant!(doro)

      api.send(:save_session_tokens)

      tokens = JSON.parse(credential.reload.session_data)["api_tokens"]
      expect(tokens).to include("restaurant_uuid" => alfios, "chat_uuid" => "chat-alfios")
    end

    it "sends no restaurant at all when asked for one the login does not have" do
      api = client
      api.restore_session

      api.select_restaurant!("not-on-this-login")

      expect(api.current_restaurant_uuid).to be_nil
    end
  end

  describe Suppliers::RestaurantMatching, ".record_count (at credential validation)" do
    let(:owner) { create(:user, :with_organization) }
    let(:usfoods) { Supplier.find_by(code: "usfoods") || create(:supplier, name: "US Foods", code: "usfoods") }

    it "notes how many restaurants an owner's login has" do
      %w[Alfios Noche].each { |n| create(:location, organization: owner.current_organization, user: owner, name: n) }
      cred = create(:supplier_credential, user: owner, supplier: usfoods, organization_id: owner.current_organization_id)
      allow(Suppliers::RestaurantSwitcher).to receive(:list_restaurants).and_return([{ id: "1" }, { id: "2" }, { id: "3" }])
      allow(usfoods).to receive(:scraper_klass).and_return(double(new: double(api_client: double)))
      allow(cred).to receive(:supplier).and_return(usfoods)

      described_class.record_count(cred)

      expect(cred.reload.supplier_restaurant_count).to eq(3)
    end

    it "skips chefs entirely" do
      org = owner.current_organization
      chef = create(:user, current_organization: org)
      create(:membership, user: chef, organization: org, role: "chef", active: true)
      cred = create(:supplier_credential, user: chef, supplier: usfoods, organization_id: org.id)
      expect(Suppliers::RestaurantSwitcher).not_to receive(:list_restaurants)

      described_class.record_count(cred)
    end

    it "never breaks validation when the supplier cannot be reached" do
      cred = create(:supplier_credential, user: owner, supplier: usfoods, organization_id: owner.current_organization_id)
      allow(Suppliers::RestaurantSwitcher).to receive(:list_restaurants).and_raise(StandardError, "timeout")
      allow(usfoods).to receive(:scraper_klass).and_return(double(new: double(api_client: double)))
      allow(cred).to receive(:supplier).and_return(usfoods)

      expect { described_class.record_count(cred) }.not_to raise_error
    end
  end
end
