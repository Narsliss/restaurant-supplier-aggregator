require "rails_helper"

# An owner connects a multi-restaurant supplier login once; EnPlace links its
# restaurants to theirs automatically, only when certain. Addresses below are
# Alfio's real ones as the suppliers report them (Sep 26-27 2026).
RSpec.describe Suppliers::RestaurantAutoLinker do
  let(:owner) { create(:user, :with_organization) }
  let(:org) { owner.current_organization }
  let!(:alfios) do
    create(:location, organization: org, user: owner, name: "Alfio's", address: "2724 Erie Avenue", city: "Cincinnati", zip_code: "45208")
  end
  let!(:noche) do
    create(:location, organization: org, user: owner, name: "Noche", address: "701 Madison Ave", city: "Covington", zip_code: "41011")
  end
  let!(:doro) do
    create(:location, organization: org, user: owner, name: "D'oro", address: "1100 Summit Place", city: "Montgomery", zip_code: "45242")
  end
  let(:usfoods) { Supplier.find_by(code: "usfoods") || create(:supplier, name: "US Foods", code: "usfoods") }
  let(:credential) do
    create(:supplier_credential, user: owner, supplier: usfoods, organization_id: org.id, location_id: alfios.id)
  end
  let(:usf_restaurants) do
    [{ id: "80998842", name: "ALFIO'S BUON CIBO PNTO — CINCINNATI", street: "2724 ERIE AVE", city: "CINCINNATI", zip: "452081234",
       meta: { "division_number" => 1103 } },
     { id: "31718356", name: "NOCHE PNTO — COVINGTON", street: "701 MADISON AVE", city: "COVINGTON", zip: "41011",
       meta: { "division_number" => 1103 } },
     { id: "11806627", name: "D ORE RESTAURANT PNTO — BLUE ASH", street: "1100 SUMMIT PL", city: "BLUE ASH", zip: "45242",
       meta: { "division_number" => 1103 } }]
  end

  before { allow(ImportSupplierListsJob).to receive(:perform_later) }

  def link(cred = credential, restaurants = usf_restaurants, **opts)
    described_class.new(cred, restaurants: restaurants, **opts).call
  end

  def links(cred = credential)
    cred.restaurants.reload.pluck(:supplier_account_id, :location_id).sort
  end

  it "links every restaurant by street number and zip, whatever the supplier calls the city" do
    link

    expect(links).to eq([["11806627", doro.id], ["31718356", noche.id], ["80998842", alfios.id]].sort)
    expect(credential.restaurants.find_by(location: noche).account_meta).to eq("division_number" => 1103)
    expect(ImportSupplierListsJob).to have_received(:perform_later).with(credential.id, force: true)
  end

  it "remembers the login's restaurants for the suppliers page" do
    link

    credential.reload
    expect(credential.supplier_restaurants.map { |r| r["id"] }).to eq(%w[80998842 31718356 11806627])
    expect(credential.supplier_restaurant_count).to eq(3)
    expect(credential.supplier_restaurants_checked_at).to be_present
  end

  it "leaves a restaurant unlinked when two of the owner's restaurants share its address" do
    doro.update!(address: "701 Madison Ave", zip_code: "41011")

    link

    expect(links.map(&:first)).to eq(%w[80998842])
  end

  it "links nothing until the login's own restaurant can be placed" do
    alfios.update!(address: "9 Somewhere Else", zip_code: "45202")

    link

    expect(links).to be_empty
    expect(credential.reload.supplier_restaurants.size).to eq(3)
  end

  it "never changes a link that already exists" do
    credential.restaurants.create!(location: alfios, supplier_account_id: "80998842")
    credential.restaurants.create!(location: doro, supplier_account_id: "31718356")

    link

    expect(links).to eq([["31718356", doro.id], ["80998842", alfios.id]].sort)
  end

  it "saves nothing on a dry run, but reports what it would link" do
    result = link(dry_run: true)

    expect(result.linked.keys).to match_array(%w[80998842 31718356 11806627])
    expect(links).to be_empty
    expect(credential.reload.supplier_restaurants).to eq([])
  end

  it "only records a single-restaurant login" do
    link(credential, usf_restaurants.first(1))

    expect(links).to be_empty
    expect(credential.reload.supplier_restaurant_count).to eq(1)
  end

  # Alfio's real setup (Sep 27 2026): the same US Foods login connected at
  # alfios (cred 75) and again at D'oro (cred 132), from before one connection
  # per supplier existed.
  describe "the same login connected twice" do
    let!(:doro_connection) do
      create(:supplier_credential, user: owner, supplier: usfoods, organization_id: org.id, location_id: doro.id)
    end

    it "leaves each restaurant to one connection, never linking one twice" do
      link
      link(doro_connection)

      expect(links).to eq([["31718356", noche.id], ["80998842", alfios.id]].sort)
      expect(links(doro_connection)).to eq([["11806627", doro.id]])
    end

    it "does not report the other connection's restaurants as unplaced or unlisted" do
      link
      link(doro_connection)

      standing = Suppliers::RestaurantLinks.new(credential.reload, [alfios, noche, doro])
      expect(standing.unplaced).to be_empty
      expect(standing.not_listed).to be_empty
    end
  end

  describe "Chef's Warehouse (no addresses in its list)" do
    let(:cw) { Supplier.find_by(code: "chefswarehouse") || create(:supplier, name: "Chef's Warehouse", code: "chefswarehouse") }
    let(:cw_login) { create(:supplier_credential, user: owner, supplier: cw, organization_id: org.id, location_id: alfios.id) }

    it "links on an exact name, ignoring case and punctuation" do
      link(cw_login, [{ id: "614969", name: "ALFIO'S" }, { id: "9508766", name: "NOCHE" }, { id: "9528299", name: "D'ORO" }])

      expect(links(cw_login)).to eq([["614969", alfios.id], ["9508766", noche.id], ["9528299", doro.id]].sort)
    end

    it "leaves a name that isn't exact for the one-click fix" do
      link(cw_login, [{ id: "614969", name: "ALFIO'S" }, { id: "9508766", name: "NOCHE COVINGTON" }])

      expect(links(cw_login)).to eq([["614969", alfios.id]])
    end
  end

  it "does not match US Foods restaurants by name" do
    usf_restaurants.each { |r| r.merge!(street: nil) }
    noche.update!(name: "NOCHE PNTO — COVINGTON")

    link

    expect(links).to be_empty
  end

  describe "PPO, where D'oro has no street" do
    let(:ppo) { Supplier.find_by(code: "premiereproduceone") || create(:supplier, name: "PPO", code: "premiereproduceone") }
    let(:ppo_login) { create(:supplier_credential, user: owner, supplier: ppo, organization_id: org.id, location_id: alfios.id) }
    let(:ppo_restaurants) do
      [{ id: "a7b88739", name: "ALFIO'S BUON CIBO — Cincinnati", street: "2724 Erie Ave", zip: "45208" },
       { id: "b2171ba1", name: "D'ORO RESTAURANT — Montgomery", street: nil, zip: "45242" }]
    end

    it "links D'oro through the restaurant saved on the D'oro chef's own PPO login" do
      michael = create(:user, current_organization: org)
      create(:membership, user: michael, organization: org, role: "chef", active: true)
      create(:supplier_credential, user: michael, supplier: ppo, organization_id: org.id, location_id: doro.id,
                                   session_data: { "api_tokens" => { "restaurant_uuid" => "b2171ba1" } }.to_json)

      link(ppo_login, ppo_restaurants)

      expect(links(ppo_login)).to eq([["a7b88739", alfios.id], ["b2171ba1", doro.id]].sort)
    end

    it "leaves D'oro for the one-click fix without a chef login to go on" do
      link(ppo_login, ppo_restaurants)

      expect(links(ppo_login)).to eq([["a7b88739", alfios.id]])
    end
  end

  describe "who it runs for" do
    it "never runs for a chef's login" do
      chef = create(:user, current_organization: org)
      create(:membership, user: chef, organization: org, role: "chef", active: true)
      chef_login = create(:supplier_credential, user: chef, supplier: usfoods, organization_id: org.id, location_id: noche.id)
      expect(Suppliers::RestaurantSwitcher).not_to receive(:list_restaurants)

      expect(described_class.new(chef_login).call).to be_nil
      expect(chef_login.reload.supplier_restaurants).to eq([])
    end

    it "never runs for an owner with one restaurant" do
      [noche, doro].each(&:destroy!)
      expect(Suppliers::RestaurantSwitcher).not_to receive(:list_restaurants)

      expect(described_class.new(credential).call).to be_nil
    end

    it "never raises from the background entry point" do
      allow(Suppliers::RestaurantSwitcher).to receive(:list_restaurants).and_raise(StandardError, "timeout")
      allow_any_instance_of(Supplier).to receive(:scraper_klass).and_return(double(new: double(api_client: double)))

      expect(described_class.run_safely(credential)).to be_nil
    end
  end
end
