class OrderListItem < ApplicationRecord
  # Associations
  belongs_to :order_list
  belongs_to :product, optional: true
  belongs_to :product_match, optional: true

  # Validations
  validates :quantity, presence: true, numericality: { greater_than: 0 }
  validate :has_product_or_match

  # Scopes
  scope :by_position, -> { order(:position, :created_at) }

  # Callbacks
  before_create :set_position

  # Delegations
  delegate :name, :category, :upc, to: :product, prefix: true, allow_nil: true

  # Display helpers — works for both product-based and match-based items
  def display_name
    product&.name || product_match&.canonical_name || "Unknown Product"
  end

  def display_unit_info
    if product
      [product.unit_size, product.unit_type].compact.join(" ")
    else
      ""
    end
  end
  delegate :user, to: :order_list

  # Methods
  def price_for(supplier)
    product.supplier_product_for(supplier)&.current_price
  end

  def line_total_for(supplier)
    price = price_for(supplier)
    price ? price * quantity : nil
  end

  def available_at?(supplier)
    product.available_at?(supplier)
  end

  def best_price
    product.supplier_products
           .available
           .where(in_stock: true)
           .where.not(current_price: nil)
           .minimum(:current_price)
  end

  def best_line_total
    bp = best_price
    bp ? bp * quantity : nil
  end

  def move_to!(new_position)
    transaction do
      if new_position < position
        order_list.order_list_items
                  .where(position: new_position...position)
                  .update_all('position = position + 1')
      else
        order_list.order_list_items
                  .where(position: (position + 1)..new_position)
                  .update_all('position = position - 1')
      end
      update!(position: new_position)
    end
  end

  private

  def set_position
    self.position ||= (order_list.order_list_items.maximum(:position) || -1) + 1
  end

  def has_product_or_match
    return if product_id.present? || product_match_id.present?
    errors.add(:base, "Must have either a product or a product match")
  end
end
