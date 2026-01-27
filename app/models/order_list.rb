class OrderList < ApplicationRecord
  # Associations
  belongs_to :user
  has_many :order_list_items, dependent: :destroy
  has_many :products, through: :order_list_items
  has_many :orders, dependent: :nullify

  # Validations
  validates :name, presence: true
  validates :name, uniqueness: { scope: :user_id }

  # Scopes
  scope :favorites, -> { where(is_favorite: true) }
  scope :recent, -> { order(last_used_at: :desc, updated_at: :desc) }
  scope :by_name, -> { order(:name) }

  # Methods
  def item_count
    order_list_items.sum(:quantity)
  end

  def estimated_total_for(supplier)
    order_list_items.includes(product: :supplier_products).sum do |item|
      sp = item.product.supplier_product_for(supplier)
      sp&.current_price ? sp.current_price * item.quantity : 0
    end
  end

  def totals_by_supplier
    suppliers = Supplier.active.includes(:supplier_products)
    
    suppliers.each_with_object({}) do |supplier, totals|
      total = estimated_total_for(supplier)
      available_count = order_list_items.count { |item| item.product.available_at?(supplier) }
      
      totals[supplier] = {
        total: total,
        available_items: available_count,
        missing_items: order_list_items.count - available_count
      }
    end
  end

  def best_supplier
    totals = totals_by_supplier
    
    # Find supplier with lowest total where all items are available
    complete_suppliers = totals.select { |_, v| v[:missing_items] == 0 }
    
    if complete_suppliers.any?
      complete_suppliers.min_by { |_, v| v[:total] }&.first
    else
      # Fall back to supplier with most available items
      totals.max_by { |_, v| v[:available_items] }&.first
    end
  end

  def duplicate!(new_name = nil)
    new_list = user.order_lists.create!(
      name: new_name || "#{name} (Copy)",
      description: description,
      is_favorite: false
    )

    order_list_items.each do |item|
      new_list.order_list_items.create!(
        product: item.product,
        quantity: item.quantity,
        notes: item.notes,
        position: item.position
      )
    end

    new_list
  end

  def mark_used!
    update!(last_used_at: Time.current)
  end

  def toggle_favorite!
    update!(is_favorite: !is_favorite)
  end

  def add_product!(product, quantity: 1, notes: nil)
    item = order_list_items.find_or_initialize_by(product: product)
    item.quantity = quantity
    item.notes = notes
    item.save!
    item
  end

  def remove_product!(product)
    order_list_items.find_by(product: product)&.destroy
  end
end
