class OrderListItem < ApplicationRecord
  # Associations
  belongs_to :order_list
  belongs_to :product

  # Validations
  validates :quantity, presence: true, numericality: { greater_than: 0 }
  validates :product_id, uniqueness: { scope: :order_list_id }

  # Scopes
  scope :by_position, -> { order(:position, :created_at) }

  # Callbacks
  before_create :set_position

  # Delegations
  delegate :name, :category, :upc, to: :product, prefix: true
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
          .update_all("position = position + 1")
      else
        order_list.order_list_items
          .where(position: (position + 1)..new_position)
          .update_all("position = position - 1")
      end
      update!(position: new_position)
    end
  end

  private

  def set_position
    self.position ||= (order_list.order_list_items.maximum(:position) || -1) + 1
  end
end
