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
