require "rails_helper"

# Stale pack weights surface in the SAME dashboard alert area as off-list
# review and credential health, rather than behind a settings page of their
# own. It is the same kind of thing — a short list of lines wanting a look —
# and a page nobody visits is not a reminder.
RSpec.describe "Stale pack weights on the dashboard", type: :request do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:supplier) { create(:supplier, name: "Chef's Warehouse") }
  let(:aggregated_list) { create(:aggregated_list, organization: organization, location_id: location.id) }

  let!(:item) do
    list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
    aggregated_list.aggregated_list_mappings.find_or_create_by!(supplier_list: list)
    sli = create(:supplier_list_item, supplier_list: list, name: "Green Bell Peppers", sku: "SKU-1",
                                      pack_size: "1 BUSHEL", price: 32.00,
                                      supplier_product: create(:supplier_product, supplier: supplier,
                                                               supplier_sku: "SKU-1", pack_size: "1 BUSHEL",
                                                               current_price: 32.00, in_stock: true))
    match = create(:product_match, aggregated_list: aggregated_list, canonical_name: "Peppers")
    create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: supplier)
    sli
  end

  def member(role)
    user = create(:user, current_organization: organization)
    m = create(:membership, user: user, organization: organization, role: role, active: true)
    m.membership_locations.create!(location: location)
    create(:subscription, user: user, organization_id: organization.id)
    create(:supplier_credential, user: user, organization: organization, location: location,
                                 supplier: supplier, status: "active")
    create(:membership, user: create(:user, current_organization: organization),
                        organization: organization, role: "chef", active: true)
    user
  end

  def set_weight(fingerprint: "1 BUSHEL")
    UnitOverride.create!(organization: organization, location: location, supplier: supplier,
                         supplier_sku: "SKU-1", basis: "per_pack", net_weight_oz: 448,
                         pack_size_fingerprint: fingerprint)
  end

  it "says nothing while the pack still matches" do
    set_weight
    sign_in member("chef")
    get root_path

    expect(response.body).not_to include("changed since you set the weight")
  end

  it "raises it in the dashboard alert area once the supplier changes the pack" do
    set_weight
    item.update!(pack_size: "20 LB")

    sign_in member("chef")
    get root_path

    expect(response.body).to include("changed since you set the weight")
    expect(response.body).to include("Green Bell Peppers")
    expect(response.body).to include("1 BUSHEL")
    expect(response.body).to include("20 LB")
    expect(response.body).to include(aggregated_list_path(aggregated_list))
  end

  it "shows an owner the same thing" do
    set_weight
    item.update!(pack_size: "20 LB")

    sign_in member("owner")
    get root_path

    expect(response.body).to include("changed since you set the weight")
  end

  # Managers create nothing anywhere in the app, so there is nothing here for
  # them to act on and no reason to nag them.
  it "leaves managers alone" do
    set_weight
    item.update!(pack_size: "20 LB")

    sign_in member("manager")
    get root_path

    expect(response.body).not_to include("changed since you set the weight")
  end

  describe "the cleanup panel on the matched list" do
    before do
      set_weight
      item.update!(pack_size: "20 LB")
      sign_in member("chef")
    end

    it "lists it beside the duplicates and husks, not on a page of its own" do
      get aggregated_list_path(aggregated_list)

      panel = Nokogiri::HTML(response.body).at_css("#cleanup")
      expect(panel).to be_present
      expect(panel.text).to include("1 pack size changed since you set the weight")
      expect(panel.text).to include("Green Bell Peppers")
      expect(panel.text).to include("Set it again")
      expect(panel.text).to include("Still right")
    end

    # The tripwire cannot tell a reworded box from a different one. The chef
    # can, and saying so re-pins the weight rather than making them retype it.
    it "re-pins the weight to today's wording when the chef says it is still right" do
      post reconfirm_unit_overrides_path(supplier_list_item_id: item.id)

      override = UnitOverride.last
      expect(override.pack_size_fingerprint).to eq("20 LB")
      expect(override.net_weight_oz).to eq(448)
      expect(item.reload.unit_override_stale?).to be(false)
    end

    it "drops out of the panel once it has been dealt with" do
      post reconfirm_unit_overrides_path(supplier_list_item_id: item.id)
      get aggregated_list_path(aggregated_list)

      expect(response.body).not_to include("changed since you set the weight")
    end

    it "refuses a manager, who cannot set weights in the first place" do
      sign_in member("manager")
      expect { post reconfirm_unit_overrides_path(supplier_list_item_id: item.id) }
        .not_to change { UnitOverride.last.pack_size_fingerprint }
    end
  end

  it "ignores a supplier merely renaming the same pack" do
    set_weight
    item.update!(pack_size: "1 BU")

    sign_in member("chef")
    get root_path

    expect(response.body).not_to include("changed since you set the weight")
  end
end
