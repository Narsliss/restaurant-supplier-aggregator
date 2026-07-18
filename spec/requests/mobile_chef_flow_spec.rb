require "rails_helper"

# Mobile-first chef flow (mobile-first-chef branch).
# Mobile variants must render for phone user agents; desktop templates must be
# untouched when no mobile variant applies.
RSpec.describe "Mobile chef flow", type: :request do
  MOBILE_UA = { "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" }.freeze

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

  before { sign_in chef }

  describe "GET /aggregated_lists/start_order" do
    it "redirects the chef straight into their order builder" do
      get start_order_aggregated_lists_path, headers: MOBILE_UA
      expect(response).to redirect_to(order_builder_aggregated_list_path(aggregated_list))
    end

    it "falls back to the list picker when nothing is matched" do
      aggregated_list.update!(match_status: "pending")
      get start_order_aggregated_lists_path, headers: MOBILE_UA
      expect(response).to redirect_to(select_list_orders_path)
    end

    it "resumes the in-progress batch (one cart) and prefills the chef's supplier pick" do
      match = aggregated_list.product_matches.first
      post create_from_aggregated_list_orders_path, params: {
        aggregated_list_id: aggregated_list.id,
        quantities: { match.id.to_s => "2" },
        supplier_overrides: { match.id.to_s => supplier.id.to_s }
      }, headers: MOBILE_UA
      batch_id = Order.last.batch_id

      get start_order_aggregated_lists_path, headers: MOBILE_UA
      expect(response).to redirect_to(order_builder_aggregated_list_path(aggregated_list, batch_id: batch_id))

      follow_redirect!(headers: MOBILE_UA.dup)
      expect(response.body).to include(%(data-initial-qty="2"))
      expect(response.body).to include(%(data-initial-supplier-id="#{supplier.id}"))
    end
  end

  describe "GET order_builder" do
    it "renders the mobile Comp A builder for phone user agents" do
      get order_builder_aggregated_list_path(aggregated_list), headers: MOBILE_UA
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("mobile-order-builder")
      expect(response.body).to include("Search all suppliers")
    end

    it "renders the unchanged desktop builder for desktop user agents" do
      get order_builder_aggregated_list_path(aggregated_list)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="order-form"')
      expect(response.body).not_to include("mobile-order-builder")
    end
  end

  describe "GET /orders/cart" do
    it "shows the empty-cart state on mobile when no batch is in progress" do
      get cart_orders_path, headers: MOBILE_UA
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Cart is empty")
    end

    it "redirects desktop users to orders" do
      get cart_orders_path
      expect(response).to redirect_to(orders_path)
    end

    it "redirects to review when a pending batch exists" do
      post create_from_aggregated_list_orders_path, params: {
        aggregated_list_id: aggregated_list.id,
        quantities: { aggregated_list.product_matches.first.id.to_s => "2" }
      }, headers: MOBILE_UA
      batch_id = Order.last.batch_id

      get cart_orders_path, headers: MOBILE_UA
      expect(response).to redirect_to(review_orders_path(batch_id: batch_id))
    end
  end

  describe "mobile review (cart page)" do
    it "creates pending orders through the existing pipeline and renders the mobile cart" do
      match = aggregated_list.product_matches.first
      expect {
        post create_from_aggregated_list_orders_path, params: {
          aggregated_list_id: aggregated_list.id,
          quantities: { match.id.to_s => "3" },
          supplier_overrides: { match.id.to_s => supplier.id.to_s }
        }, headers: MOBILE_UA
      }.to change(Order.where(status: "pending"), :count).by(1)

      order = Order.last
      expect(order.supplier).to eq(supplier)
      expect(order.order_items.first.quantity).to eq(3)

      follow_redirect!(headers: MOBILE_UA.dup)
      expect(response.body).to include("Your Cart")
      expect(response.body).to include("mobile-review")
    end

    it "renders the unchanged desktop review for desktop user agents" do
      post create_from_aggregated_list_orders_path, params: {
        aggregated_list_id: aggregated_list.id,
        quantities: { aggregated_list.product_matches.first.id.to_s => "1" }
      }
      follow_redirect!
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("mobile-review")
    end
  end

  describe "mobile dashboard" do
    it "renders the ordering-centric chef dashboard with the 3-tab bar" do
      get root_path, headers: MOBILE_UA
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Start an Order")
      expect(response.body).to include(start_order_aggregated_lists_path)
      expect(response.body).to include(cart_orders_path)
    end
  end
end
