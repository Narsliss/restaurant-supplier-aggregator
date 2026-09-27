require "rails_helper"

# An owner's one supplier login can order for several restaurants. Before any
# sync or order for a restaurant, the login is switched to it and the switch is
# CONFIRMED; afterwards it goes back home. Connections with no restaurant
# matches (every chef) must pass straight through untouched.
RSpec.describe Suppliers::RestaurantSwitcher do
  let(:owner) { create(:user, :with_organization) }
  let(:org) { owner.current_organization }
  let(:alfios) { create(:location, organization: org, user: owner, name: "Alfios") }
  let(:noche) { create(:location, organization: org, user: owner, name: "Noche") }
  let(:usfoods) { Supplier.find_by(code: "usfoods") || create(:supplier, name: "US Foods", code: "usfoods") }
  let(:credential) do
    create(:supplier_credential, user: owner, supplier: usfoods, organization_id: org.id, location_id: alfios.id)
  end
  let(:api) { FakeRestaurantApi.new(current: "80998842") }

  def match!(location, account_id)
    credential.restaurants.create!(location: location, supplier_account_id: account_id,
                                   account_meta: { "division_number" => 1103 })
  end

  context "a connection with no restaurant matches" do
    it "runs the work without switching anything" do
      ran = false
      described_class.new(credential, api).with_restaurant(noche.id) { ran = true }

      expect(ran).to be(true)
      expect(api.switches).to be_empty
    end
  end

  context "a multi-restaurant login" do
    before do
      match!(alfios, "80998842")
      match!(noche, "31718356")
    end

    it "switches to the location's restaurant, does the work there, then goes back home" do
      seen = nil
      described_class.new(credential, api).with_restaurant(noche.id) { seen = api.current }

      expect(seen).to eq("31718356")
      expect(api.switches).to eq(%w[31718356 80998842])
      expect(api.current).to eq("80998842")
    end

    it "switches deliberately even for the home restaurant, never trusting where the login was left" do
      api.current = "31718356" # left on Noche by something else
      seen = nil
      described_class.new(credential, api).with_restaurant(alfios.id) { seen = api.current }

      expect(seen).to eq("80998842")
    end

    it "refuses to do the work when the supplier did not actually switch" do
      api.ignore_switch = true
      ran = false

      expect do
        described_class.new(credential, api).with_restaurant(noche.id) { ran = true }
      end.to raise_error(described_class::MismatchError, /not .*31718356/)
      expect(ran).to be(false)
    end

    it "still goes back home when the work fails, and the work's error is not masked" do
      expect do
        described_class.new(credential, api).with_restaurant(noche.id) { raise ArgumentError, "cart blew up" }
      end.to raise_error(ArgumentError, "cart blew up")
      expect(api.current).to eq("80998842")
    end

    it "refuses a restaurant the login isn't linked to, without switching or doing the work" do
      dor = create(:location, organization: org, user: owner, name: "D'oro")
      ran = false

      expect do
        described_class.new(credential, api).with_restaurant(dor.id) { ran = true }
      end.to raise_error(described_class::MismatchError, /isn't linked/)
      expect(api.switches).to be_empty
      expect(ran).to be(false)
    end

    it "supports the begin/ensure form used by order placement" do
      switcher = described_class.new(credential, api)

      expect(switcher.enter(noche.id)).to be(true)
      expect(api.current).to eq("31718356")
      switcher.leave
      expect(api.current).to eq("80998842")
    end

    it "uses a scraper's own API client, so the work runs on the switched session" do
      scraper = Struct.new(:api_client).new(api)
      described_class.new(credential, scraper).with_restaurant(noche.id) { nil }

      expect(api.switches.first).to eq("31718356")
    end
  end

  # PPO keeps no server-side "current restaurant": the real client is driven
  # here, with only Pepper's restaurant list stubbed.
  context "a Premiere ProduceOne login" do
    let(:ppo) do
      Supplier.find_by(code: "premiereproduceone") || create(:supplier, name: "Premiere ProduceOne", code: "premiereproduceone")
    end
    let(:doro) { create(:location, organization: org, user: owner, name: "D'oro") }
    let(:credential) do
      create(:supplier_credential, user: owner, supplier: ppo, organization_id: org.id, location_id: alfios.id,
                                   session_data: { "api_tokens" => { "id_token" => "tok", "restaurant_uuid" => "r-alfios" } }.to_json)
    end
    let(:api) do
      Scrapers::PremiereProduceOneApi.new(credential).tap do |client|
        allow(client).to receive(:graphql).and_return("employee_chats" => [
          { "chat_uuid" => "c-alfios", "restaurant_uuid" => "r-alfios", "supplier_uuid" => "s" },
          { "chat_uuid" => "c-doro", "restaurant_uuid" => "r-doro", "supplier_uuid" => "s" }
        ])
      end
    end

    before do
      credential.restaurants.create!(location: alfios, supplier_account_id: "r-alfios")
      credential.restaurants.create!(location: doro, supplier_account_id: "r-doro")
    end

    it "carries D'oro's restaurant on every call inside the block, then goes back home" do
      seen = nil
      described_class.new(credential, api).with_restaurant(doro.id) { seen = [api.restaurant_uuid, api.chat_uuid] }

      expect(seen).to eq(%w[r-doro c-doro])
      expect(api.restaurant_uuid).to eq("r-alfios")
    end

    it "refuses when the login no longer has the matched restaurant" do
      credential.restaurant_for(doro).update!(supplier_account_id: "r-gone")
      ran = false

      expect do
        described_class.new(credential, api).with_restaurant(doro.id) { ran = true }
      end.to raise_error(described_class::MismatchError)
      expect(ran).to be(false)
      expect(api.restaurant_uuid).to eq("r-alfios")
    end
  end

  describe "who can have restaurant matches" do
    it "refuses a chef's connection" do
      chef = create(:user, current_organization: org)
      create(:membership, user: chef, organization: org, role: "chef", active: true)
      chef_cred = create(:supplier_credential, user: chef, supplier: usfoods, organization_id: org.id, location_id: noche.id)

      match = chef_cred.restaurants.build(location: noche, supplier_account_id: "31718356")

      expect(match).not_to be_valid
      expect(match.errors.full_messages.join).to include("Only owners and managers")
    end

    it "refuses another restaurant before the login's own one is linked" do
      match = credential.restaurants.build(location: noche, supplier_account_id: "31718356")

      expect(match).not_to be_valid
      expect(match.errors.full_messages.join).to include("own restaurant first")
    end

    it "refuses a location from another organization" do
      other = create(:location, organization: create(:organization))
      match = credential.restaurants.build(location: other, supplier_account_id: "1")

      expect(match).not_to be_valid
    end
  end
end
