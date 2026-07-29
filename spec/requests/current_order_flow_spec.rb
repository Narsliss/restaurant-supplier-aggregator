require "rails_helper"

# The chef's singular working order (mobile Order tab vision):
# - every add/remove saves it (PUT /current_order)
# - returning to the builder repopulates from it
# - Create Cart reseeds the batch from it WITHOUT clearing it
# - Create Cart always destroys the user's previous in-progress batch
# - placing the order clears it; "Clear order" (DELETE) clears it manually
RSpec.describe "Current order flow", type: :request do
  MOBILE_UA_CO = { "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" }.freeze

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

  let!(:aggregated_list) do
    list = create(:aggregated_list, organization: organization, location_id: location.id)
    supplier_list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
    list.aggregated_list_mappings.find_or_create_by!(supplier_list: supplier_list)
    sli = create(:supplier_list_item, supplier_list: supplier_list, name: "Chicken Breast", price: 68.90,
                                      supplier_product: create(:supplier_product, supplier: supplier, current_price: 68.90, in_stock: true))
    match = create(:product_match, aggregated_list: list, canonical_name: "Chicken Breast")
    create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: supplier)
    list
  end
  let(:match) { aggregated_list.product_matches.first }

  before { sign_in chef }

  def put_current_order(qty: 3)
    put current_order_path, params: {
      aggregated_list_id: aggregated_list.id,
      state: { match.id.to_s => { supplierId: supplier.id.to_s, qty: qty, uom: "CS" } },
      delivery_date: Date.tomorrow.iso8601
    }, as: :json
  end

  describe "PUT /current_order" do
    it "saves the working order and the builder repopulates from it" do
      put_current_order(qty: 3)
      expect(response).to have_http_status(:no_content)

      co = CurrentOrder.find_by(user: chef, aggregated_list: aggregated_list)
      expect(co.sanitized_state[match.id.to_s]).to include("qty" => 3.0, "supplierId" => supplier.id.to_s)

      get order_builder_aggregated_list_path(aggregated_list), headers: MOBILE_UA_CO
      expect(response.body).to include(%(data-initial-qty="3"))
      expect(response.body).to include(%(data-initial-supplier-id="#{supplier.id}"))
    end

    it "upserts — a second save replaces the state" do
      put_current_order(qty: 3)
      put_current_order(qty: 5)
      expect(CurrentOrder.where(user: chef).count).to eq(1)
      expect(CurrentOrder.last.sanitized_state[match.id.to_s]["qty"]).to eq(5.0)
    end

    it "rejects lists outside the chef's organization" do
      foreign_list = create(:aggregated_list)
      put current_order_path, params: { aggregated_list_id: foreign_list.id, state: {} }, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /current_order (Clear order)" do
    it "empties the working order" do
      put_current_order
      delete current_order_path, params: { aggregated_list_id: aggregated_list.id }
      expect(response).to have_http_status(:no_content)
      expect(CurrentOrder.where(user: chef)).to be_empty
    end
  end

  describe "Create Cart semantics" do
    def create_cart
      post create_from_aggregated_list_orders_path, params: {
        aggregated_list_id: aggregated_list.id,
        quantities: { match.id.to_s => "2" },
        supplier_overrides: { match.id.to_s => supplier.id.to_s }
      }, headers: MOBILE_UA_CO
    end

    it "does NOT clear the working order" do
      put_current_order
      create_cart
      expect(CurrentOrder.where(user: chef)).to exist
    end

    # Regression: the builder path bulk-inserts order items (insert_all skips
    # the snapshot callback), which left product_name nil — order views showed
    # bare SKUs instead of item names.
    it "snapshots product names onto bulk-inserted order items" do
      create_cart
      item = Order.order(:id).last.order_items.first
      expect(item.product_name).to eq(item.supplier_product.supplier_name)
      expect(item.product_sku).to eq(item.supplier_product.supplier_sku)
    end

    it "always destroys the user's previous in-progress batch (reseed)" do
      create_cart
      first_batch = Order.order(:id).last.batch_id
      create_cart
      second_batch = Order.order(:id).last.batch_id

      expect(second_batch).not_to eq(first_batch)
      expect(Order.where(batch_id: first_batch)).to be_empty
      expect(Order.where(batch_id: second_batch)).to exist
    end

    it "does not touch another user's in-progress batch" do
      other_chef = create(:user, current_organization: organization)
      create(:membership, user: other_chef, organization: organization, role: "chef", active: true)
      other_order = create(:order, user: other_chef, organization: organization, supplier: supplier,
                                   location: location, status: "pending", batch_id: SecureRandom.uuid)

      create_cart
      expect(Order.exists?(other_order.id)).to be true
    end
  end

  describe "placing the order" do
    it "clears the working order after submit_batch" do
      put_current_order
      post create_from_aggregated_list_orders_path, params: {
        aggregated_list_id: aggregated_list.id,
        quantities: { match.id.to_s => "2" },
        supplier_overrides: { match.id.to_s => supplier.id.to_s }
      }, headers: MOBILE_UA_CO
      batch_id = Order.order(:id).last.batch_id
      Order.where(batch_id: batch_id).update_all(status: "draft", delivery_date: Date.tomorrow)

      post submit_batch_orders_path, params: { batch_id: batch_id }, headers: MOBILE_UA_CO

      expect(CurrentOrder.where(user: chef)).to be_empty
      expect(Order.where(batch_id: batch_id).pluck(:status)).to all(eq("processing"))
    end
  end
end
