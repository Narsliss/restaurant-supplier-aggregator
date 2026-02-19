class ProductMatchItem < ApplicationRecord
  # Associations
  belongs_to :product_match
  belongs_to :supplier_list_item
  belongs_to :supplier

  # Validations
  validates :supplier_id, uniqueness: {
    scope: :product_match_id,
    message: 'already has an item in this match'
  }

  # Delegations
  delegate :name, :sku, :price, :pack_size, :in_stock, :formatted_price, to: :supplier_list_item
  delegate :aggregated_list, to: :product_match
end
