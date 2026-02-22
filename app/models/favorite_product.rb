class FavoriteProduct < ApplicationRecord
  belongs_to :user
  belongs_to :supplier_product

  validates :supplier_product_id, uniqueness: { scope: :user_id }
end
