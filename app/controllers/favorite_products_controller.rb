class FavoriteProductsController < ApplicationController
  before_action :authenticate_user!

  def toggle
    sp_id = params[:supplier_product_id]
    favorite = current_user.favorite_products.find_by(supplier_product_id: sp_id)

    if favorite
      favorite.destroy!
      render json: { favorited: false }
    else
      current_user.favorite_products.create!(supplier_product_id: sp_id)
      render json: { favorited: true }
    end
  end
end
