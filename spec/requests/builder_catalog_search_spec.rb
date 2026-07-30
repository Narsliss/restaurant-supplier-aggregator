require "rails_helper"

# Chefs must be able to order anything a connected supplier carries, mid-shift,
# whether or not it has been curated onto a list (Carmin 2026-07-30: desktop
# global search found 223 "truffle" products; the mobile Order page found 3).
# The mobile builder now searches the full catalog under "Everything else" and
# one tap makes a product orderable.
RSpec.describe "Mobile builder full-catalog search", type: :request do
  MOBILE_UA_CS = { "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" }.freeze

  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:chef) do
    user = create(:user, current_organization: organization)
    membership = create(:membership, user: user, organization: organization, role: "chef", active: true)
    membership.membership_locations.create!(location: location)
    user
  end
  let(:supplier) { create(:supplier) }
  let!(:subscription) { create(:subscription, user: chef, organization_id: organization.id) }
  let!(:credential) do
    create(:supplier_credential, user: chef, organization: organization, location: location,
                                 supplier: supplier, status: "active")
  end

  # A matched list holding ONE truffle product...
  let!(:aggregated_list) do
    list = create(:aggregated_list, organization: organization, location_id: location.id,
                                    list_type: "matched", match_status: "matched")
    supplier_list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
    list.aggregated_list_mappings.find_or_create_by!(supplier_list: supplier_list)
    sli = create(:supplier_list_item, supplier_list: supplier_list, name: "Black Truffle Carpaccio",
                                      price: 40.00, supplier_product: on_list_product)
    match = create(:product_match, aggregated_list: list, canonical_name: "Black Truffle Carpaccio")
    create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: supplier)
    list
  end
  let(:on_list_product) do
    create(:supplier_product, supplier: supplier, supplier_name: "Black Truffle Carpaccio",
                              current_price: 40.00, in_stock: true)
  end
  # ...and two more that only exist in the supplier's catalog
  let!(:catalog_truffle) do
    create(:supplier_product, supplier: supplier, supplier_name: "TRUFFLE OIL WHITE 8 OZ",
                              current_price: 22.50, pack_size: "12/8 OZ", in_stock: true)
  end
  let!(:catalog_truffle_b) do
    create(:supplier_product, supplier: supplier, supplier_name: "Aged Truffle Pecorino",
                              current_price: 88.00, in_stock: true)
  end
  let!(:unrelated) do
    create(:supplier_product, supplier: supplier, supplier_name: "CHICKEN THIGH BONELESS", current_price: 60.00)
  end

  before { sign_in chef }

  def search(q)
    get builder_catalog_search_aggregated_list_path(aggregated_list, q: q), headers: MOBILE_UA_CS
    JSON.parse(response.body)
  end

  describe "GET builder_catalog_search" do
    it "finds catalog products that are NOT on the matched list" do
      body = search("truffle")

      names = body["results"].map { |r| r["name"] }
      expect(names).to include("TRUFFLE OIL WHITE 8 OZ", "Aged Truffle Pecorino")
      expect(names).not_to include("Black Truffle Carpaccio") # already shown above
      expect(names).not_to include("CHICKEN THIGH BONELESS")
      expect(body["total"]).to eq(2)
      expect(body["capped"]).to be false
    end

    it "sorts alphabetically so scanning chefs don't think items are missing" do
      names = search("truffle")["results"].map { |r| r["name"] }
      expect(names).to eq(names.sort_by(&:downcase))
    end

    it "returns case-equivalent prices and pack info for each row" do
      row = search("truffle")["results"].find { |r| r["name"] == "TRUFFLE OIL WHITE 8 OZ" }

      expect(row["price"]).to eq(22.50)
      expect(row["pack_size"]).to eq("12/8 OZ")
      expect(row["supplier_product_id"]).to eq(catalog_truffle.id)
      expect(row["in_stock"]).to be true
    end

    it "ignores queries shorter than two characters" do
      expect(search("t")).to include("results" => [], "total" => 0)
    end

    it "never returns products from suppliers the chef has no active login for" do
      credential.update!(status: "failed")
      expect(search("truffle")["results"]).to be_empty
    end
  end

  describe "POST builder_add_catalog_item" do
    def add(product)
      post builder_add_catalog_item_aggregated_list_path(aggregated_list),
           params: { supplier_product_id: product.id }, headers: MOBILE_UA_CS, as: :json
      JSON.parse(response.body)
    end

    it "makes the product orderable and returns card data for the builder" do
      expect { add(catalog_truffle) }.to change { aggregated_list.product_matches.count }.by(1)

      body = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(body["display_name"]).to eq("TRUFFLE OIL WHITE 8 OZ")
      expect(body["supplier_id"]).to eq(supplier.id)
      expect(body["price"]).to eq(22.50)
      expect(body["match_id"]).to be_present
    end

    it "creates the records the ordering pipeline needs" do
      match = ProductMatch.find(add(catalog_truffle)["match_id"])
      item = match.product_match_items.first.supplier_list_item

      expect(item.supplier_product_id).to eq(catalog_truffle.id)
      expect(item.source).to eq("catalog")
      # The order service resolves a supplier via ProductMatch#cheapest_supplier
      expect(match.cheapest_supplier[:item]).to eq(item)
    end

    it "is idempotent — adding twice reuses the same match" do
      first = add(catalog_truffle)["match_id"]
      expect { add(catalog_truffle) }.not_to change { aggregated_list.product_matches.count }
      expect(add(catalog_truffle)["match_id"]).to eq(first)
    end

    it "then appears in the matched-list search instead of the catalog section" do
      add(catalog_truffle)
      expect(search("truffle")["results"].map { |r| r["name"] }).not_to include("TRUFFLE OIL WHITE 8 OZ")
    end

    it "refuses a supplier the chef has no active login for" do
      other_product = create(:supplier_product, supplier: create(:supplier), supplier_name: "TRUFFLE SALT")

      post builder_add_catalog_item_aggregated_list_path(aggregated_list),
           params: { supplier_product_id: other_product.id }, headers: MOBILE_UA_CS, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(aggregated_list.product_matches.reload.count).to eq(1)
    end

    it "404s on an unknown product" do
      post builder_add_catalog_item_aggregated_list_path(aggregated_list),
           params: { supplier_product_id: 0 }, headers: MOBILE_UA_CS, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the builder page itself" do
    it "renders supplier names on cards so tier-1/2 search matches them" do
      get order_builder_aggregated_list_path(aggregated_list), headers: MOBILE_UA_CS
      expect(response.body).to include("data-supplier-names=")
    end

    it "renders all three group headers" do
      get order_builder_aggregated_list_path(aggregated_list), headers: MOBILE_UA_CS
      expect(response.body).to include("From your order lists")
      expect(response.body).to include("From your matched lists")
      expect(response.body).to include("Everything else")
    end
  end
end
