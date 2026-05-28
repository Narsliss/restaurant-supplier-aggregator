class TeaserMatch < ApplicationRecord
  belongs_to :aggregated_list
  belongs_to :product_match
  belongs_to :supplier
  belongs_to :supplier_product

  validates :product_match_id, uniqueness: { scope: :supplier_id }
end
