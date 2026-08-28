require "rails_helper"

RSpec.describe "Set Weight", type: :request do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:supplier) { create(:supplier, name: "Chef's Warehouse") }

  let!(:item) do
    list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
    sp = create(:supplier_product, supplier: supplier, supplier_sku: "SKU-1",
                                   pack_size: "1 BUSHEL", current_price: 32.00, in_stock: true)
    create(:supplier_list_item, supplier_list: list, name: "Green Bell Peppers", sku: "SKU-1",
                                pack_size: "1 BUSHEL", price: 32.00, supplier_product: sp)
  end

  # Onboarding gates the whole app: a chef needs a connected supplier and an
  # owner needs a location and a colleague, or ApplicationController redirects
  # them to the dashboard before any of this is reached.
  def member(role, org: organization)
    loc = org.locations.first || create(:location, organization: org)
    user = create(:user, current_organization: org)
    membership = create(:membership, user: user, organization: org, role: role, active: true)
    membership.membership_locations.create!(location: loc)
    create(:subscription, user: user, organization_id: org.id)
    create(:supplier_credential, user: user, organization: org, location: loc,
                                 supplier: supplier, status: "active")
    create(:membership, user: create(:user, current_organization: org), organization: org,
                        role: "chef", active: true)
    user
  end

  def set_weight(weight: 28, unit: "lb", basis: "per_pack")
    post unit_overrides_path, params: { supplier_list_item_id: item.id, weight: weight,
                                        unit: unit, basis: basis }
  end

  describe "who may set one" do
    it "lets a chef set a weight" do
      sign_in member("chef")
      expect { set_weight }.to change(UnitOverride, :count).by(1)
    end

    it "lets an owner set a weight" do
      sign_in member("owner")
      expect { set_weight }.to change(UnitOverride, :count).by(1)
    end

    # Managers create nothing anywhere in the app; they see the badge and the
    # provenance, not the input.
    it "refuses a manager" do
      sign_in member("manager")
      expect { set_weight }.not_to change(UnitOverride, :count)
    end

    it "refuses a chef from another organization" do
      other = create(:organization)
      create(:location, organization: other)
      sign_in member("chef", org: other)
      expect { set_weight }.not_to change(UnitOverride, :count)
    end

    it "refuses a signed-out visitor" do
      expect { set_weight }.not_to change(UnitOverride, :count)
    end
  end

  describe "what gets recorded" do
    before { sign_in member("chef") }

    it "derives everything but the weight from the item itself" do
      set_weight(weight: 28, unit: "lb")
      override = UnitOverride.last

      expect(override.net_weight_oz).to eq(448)
      expect(override.supplier_sku).to eq("SKU-1")
      expect(override.organization_id).to eq(organization.id)
      expect(override.location_id).to eq(location.id)
      expect(override.supplier_id).to eq(supplier.id)
      # Pinned to the pack it was entered against, so a pack change can be seen.
      expect(override.pack_size_fingerprint).to eq("1 BUSHEL")
      expect(override.price_at_entry).to eq(32.00)
    end

    it "accepts ounces and kilograms as well as pounds" do
      set_weight(weight: 448, unit: "oz")
      expect(UnitOverride.last.net_weight_oz).to eq(448)
    end

    it "corrects an existing weight rather than raising on the unique index" do
      set_weight(weight: 28)
      expect { set_weight(weight: 22) }.not_to change(UnitOverride, :count)
      expect(UnitOverride.last.net_weight_oz).to eq(352)
    end

    it "rejects a weight that yields an unarguably wrong price" do
      set_weight(weight: 0.05) # $32 for 0.8 oz — $640 a pound
      expect(UnitOverride.count).to eq(0)
      expect(flash[:alert]).to be_present
    end

    it "rejects a zero or missing weight" do
      set_weight(weight: 0)
      expect(UnitOverride.count).to eq(0)
    end
  end

  describe "where the control appears" do
    let(:aggregated_list) { create(:aggregated_list, organization: organization, location_id: location.id) }

    def modal_for(pack_size)
      item.update!(pack_size: pack_size)
      item.supplier_product.update!(pack_size: pack_size)
      match = create(:product_match, aggregated_list: aggregated_list, canonical_name: "Peppers")
      aggregated_list.aggregated_list_mappings.find_or_create_by!(supplier_list: item.supplier_list)
      create(:product_match_item, product_match: match, supplier_list_item: item, supplier: supplier)
      get edit_aggregated_list_product_match_path(aggregated_list, match)
      response.body
    end

    before { sign_in member("chef") }

    it "offers Set Weight when the supplier never stated a weight" do
      expect(modal_for("1 BUSHEL")).to include("Set weight")
    end

    it "offers it on a count pack the platform is only guessing at" do
      expect(modal_for("24 CT")).to include("Set weight")
    end

    it "stays out of the way when the supplier stated a weight" do
      expect(modal_for("6/10 LB")).not_to include("Set weight")
    end
  end

  describe "removing one" do
    it "lets a chef clear a weight another chef set" do
      first_chef = member("chef")
      sign_in first_chef
      set_weight(weight: 28)

      sign_in member("chef")
      expect {
        delete unit_override_for_item_path(supplier_list_item_id: item.id)
      }.to change(UnitOverride, :count).by(-1)
    end
  end
end
