require 'rails_helper'

RSpec.describe 'OrderLists', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:product) { create(:product) }

  before { sign_in owner }

  describe 'GET /order_lists' do
    it 'returns 200' do
      get order_lists_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /order_lists' do
    it 'creates an order list' do
      expect {
        post order_lists_path, params: { order_list: { name: 'Weekly Mise' } }
      }.to change(OrderList, :count).by(1)
      expect(response).to be_redirect
    end
  end

  describe 'POST /order_lists/refresh_recent' do
    let(:location) { org.locations.first }
    let(:supplier) { create(:supplier, name: 'US Foods') }
    let!(:credential) do
      create(:supplier_credential, supplier: supplier, user: owner,
                                   organization_id: org.id, location_id: location.id, status: 'active')
    end

    it 'creates the seeded recent-orders list on demand (legacy chefs included)' do
      # Location already curates its own list — auto-seeding would skip it,
      # the chef-pressed button must not.
      OrderList.create!(user: owner, organization: org, location: location, name: 'My prep list')

      source = create(:supplier_list, supplier: supplier, organization: org, location: location,
                                      list_type: 'recently_purchased', remote_list_id: 'recentlyPurchased')
      sp = create(:supplier_product, supplier: supplier, supplier_sku: 'A',
                                     product: create(:product))
      create(:supplier_list_item, supplier_list: source, sku: 'A', name: 'Item A',
                                  position: 0, supplier_product: sp)

      expect {
        post refresh_recent_order_lists_path
      }.to change { OrderList.where.not(seed_supplier_id: nil).count }.by(1)

      expect(response).to redirect_to(order_lists_path)
      expect(flash[:notice]).to include('Recent US Foods Orders')
    end

    it 'reports up-to-date when there is nothing new' do
      post refresh_recent_order_lists_path
      expect(response).to redirect_to(order_lists_path)
    end

    # Chef mental model (Carmin): "Refresh Recent Orders" must actually GO
    # to the supplier — a press with no local seed source enqueues a live
    # forced fetch that re-seeds when it lands.
    it 'kicks off a live forced fetch per connected supplier' do
      expect {
        post refresh_recent_order_lists_path
      }.to have_enqueued_job(ImportSupplierListsJob)
        .with(credential.id, force: true, refresh_seeded: true)
      expect(flash[:notice]).to include('background')
    end
  end

  describe 'GET /order_lists/:id' do
    let!(:list) { OrderList.create!(user: owner, organization: org, location: org.locations.first, name: 'Test list') }

    it 'returns 200' do
      get order_list_path(list)
      expect(response).to have_http_status(:ok)
    end

    it 'returns 404 for a list in another organization' do
      other_user = create(:user, :fully_onboarded)
      other_org = other_user.current_organization
      other_list = OrderList.create!(user: other_user, organization: other_org, location: other_org.locations.first, name: 'Foreign')

      get order_list_path(other_list)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /order_lists/:id/duplicate' do
    let!(:list) { OrderList.create!(user: owner, organization: org, location: org.locations.first, name: 'Source') }

    it 'duplicates the list and redirects' do
      expect {
        post duplicate_order_list_path(list)
      }.to change(OrderList, :count).by(1)
      expect(response).to be_redirect
    end
  end

  describe 'auth gate' do
    it 'redirects unauthenticated' do
      sign_out owner
      get order_lists_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end

RSpec.describe 'OrderListItems (nested)', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:product) { create(:product) }
  let!(:order_list) { OrderList.create!(user: owner, organization: org, location: org.locations.first, name: 'My list') }

  before { sign_in owner }

  describe 'POST /order_lists/:order_list_id/order_list_items' do
    it 'adds an item to the list' do
      expect {
        post order_list_order_list_items_path(order_list), params: { order_list_item: { product_id: product.id, quantity: 3 } }
      }.to change { order_list.order_list_items.count }.by(1)
    end
  end

  describe 'DELETE /order_lists/:order_list_id/order_list_items/:id' do
    let!(:item) { order_list.order_list_items.create!(product: product, quantity: 1) }

    it 'removes the item' do
      expect {
        delete order_list_order_list_item_path(order_list, item)
      }.to change { order_list.order_list_items.count }.by(-1)
    end
  end
end

RSpec.describe 'FavoriteProducts', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:product) { create(:product) }

  before { sign_in owner }

  it 'POST /favorite_products/toggle adds and removes the favorite' do
    expect {
      post toggle_favorite_products_path, params: { product_id: product.id }
    }.to change { owner.favorite_products.count }.by(1)

    expect {
      post toggle_favorite_products_path, params: { product_id: product.id }
    }.to change { owner.favorite_products.count }.by(-1)
  end
end
