require "rails_helper"

# Chefs can order anything mid-shift (commit 31cf631). Those items land with one
# supplier and no price comparison, so owners/managers must be told and the item
# stays flagged until someone looks at it. Carmin 2026-07-30: "if that chef
# picked the most expensive truffle oil that could cause org wide problems".
RSpec.describe "Off-list order review", type: :request do
  MOBILE_UA_OL = { "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" }.freeze

  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:supplier) { create(:supplier) }

  let(:chef) do
    user = create(:user, current_organization: organization)
    m = create(:membership, user: user, organization: organization, role: "chef", active: true)
    m.membership_locations.create!(location: location)
    user
  end
  let!(:owner) do
    user = create(:user, email: "owner@example.test", current_organization: organization)
    m = create(:membership, user: user, organization: organization, role: "owner", active: true)
    m.membership_locations.create!(location: location)
    user
  end
  let!(:manager) do
    user = create(:user, email: "manager@example.test", current_organization: organization)
    m = create(:membership, user: user, organization: organization, role: "manager", active: true)
    m.membership_locations.create!(location: location)
    user
  end

  let!(:chef_subscription) { create(:subscription, user: chef, organization_id: organization.id) }
  let!(:owner_subscription) { create(:subscription, user: owner, organization_id: organization.id) }
  let!(:credential) do
    create(:supplier_credential, user: chef, organization: organization, location: location,
                                 supplier: supplier, status: "active")
  end
  let!(:owner_credential) do
    create(:supplier_credential, user: owner, organization: organization, location: location,
                                 supplier: supplier, status: "active")
  end

  let!(:aggregated_list) do
    list = create(:aggregated_list, organization: organization, location_id: location.id,
                                    list_type: "matched", match_status: "matched")
    supplier_list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
    list.aggregated_list_mappings.find_or_create_by!(supplier_list: supplier_list)
    list
  end
  let!(:catalog_product) do
    create(:supplier_product, supplier: supplier, supplier_name: "WHITE TRUFFLE OIL 8 OZ",
                              current_price: 163.25, in_stock: true)
  end

  def chef_adds_off_list
    sign_in chef
    post builder_add_catalog_item_aggregated_list_path(aggregated_list),
         params: { supplier_product_id: catalog_product.id }, headers: MOBILE_UA_OL, as: :json
    ProductMatch.find(JSON.parse(response.body)["match_id"])
  end

  describe "flagging" do
    it "marks a chef's off-list add as needing review, attributed to them" do
      match = chef_adds_off_list

      expect(match).to be_off_list_added
      expect(match).to be_needs_off_list_review
      expect(match.off_list_added_by).to eq(chef)
    end

    it "does not flag adds made without a chef context (desktop curation)" do
      match = Catalog::AddProductToMatchedListService.new(
        supplier_product: catalog_product, organization: organization,
        location: location, matched_list: aggregated_list
      ).call

      expect(match).not_to be_off_list_added
      expect(match).not_to be_needs_off_list_review
    end

    it "clears the flag when an owner confirms the match" do
      match = chef_adds_off_list
      match.confirm!

      expect(match.reload).not_to be_needs_off_list_review
      expect(match.reviewed_at).to be_present
    end
  end

  describe "notification" do
    it "emails owners and managers, not the chef" do
      expect { chef_adds_off_list }.to have_enqueued_job(NotifyOffListOrderJob)

      perform_enqueued_jobs
      mail = ActionMailer::Base.deliveries.last
      expect(mail).to be_present
      expect(mail.to).to contain_exactly("owner@example.test", "manager@example.test")
      expect(mail.subject).to include("not on your matched lists")
      expect(mail.body.encoded).to include("WHITE TRUFFLE OIL 8 OZ")
    end

    it "a failed email never breaks the chef's order" do
      allow(OffListOrderMailer).to receive(:off_list_product_added).and_raise(StandardError, "smtp down")

      expect { chef_adds_off_list; perform_enqueued_jobs }.not_to raise_error
      expect(aggregated_list.product_matches.count).to eq(1)
    end
  end

  describe "matching page" do
    it "sorts unreviewed items to the top and badges them" do
      # An ordinary match that sits at position 0 until an off-list add arrives
      create(:product_match, aggregated_list: aggregated_list, canonical_name: "Ordinary Item", position: 0)
      match = chef_adds_off_list

      sign_in owner
      # explicit HTML Accept: the preceding add was a JSON request
      get aggregated_list_path(aggregated_list), headers: { "Accept" => "text/html" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Needs review")
      expect(response.body.index(match.display_name)).to be < response.body.index("Ordinary Item")
    end
  end

  describe "dashboard alert" do
    it "warns owners with a count and a link to matching" do
      chef_adds_off_list

      sign_in owner
      get root_path, headers: { "Accept" => "text/html" }

      expect(response.body).to include("ordered without price comparison")
      expect(response.body).to include(aggregated_list_path(aggregated_list))
    end

    it "stops warning once the item is reviewed" do
      chef_adds_off_list.confirm!

      sign_in owner
      get root_path, headers: { "Accept" => "text/html" }
      expect(response.body).not_to include("ordered without price comparison")
    end

    it "does not nag chefs — curation is an owner/manager job" do
      chef_adds_off_list
      get root_path, headers: MOBILE_UA_OL.merge("Accept" => "text/html") # still signed in as chef

      expect(response.body).not_to include("ordered without price comparison")
    end
  end
end
