class OrderList < ApplicationRecord
  # Associations
  belongs_to :user
  belongs_to :organization, optional: true
  belongs_to :location, optional: true
  belongs_to :seed_supplier, class_name: 'Supplier', optional: true
  has_many :order_list_items, dependent: :destroy
  has_many :products, through: :order_list_items
  has_many :orders, dependent: :nullify

  before_validation :set_organization_from_user, on: :create

  # Validations
  validates :name, presence: true
  validates :name, uniqueness: { scope: :location_id }

  # Organization scopes
  scope :for_location, ->(loc) { where(location: loc) }
  scope :for_locations, ->(locs) { where(location_id: locs.select(:id)) }
  scope :for_organization, ->(org) { where(organization_id: org.id) }

  # Scopes
  scope :favorites, -> { where(is_favorite: true) }
  scope :recent, -> { order(last_used_at: :desc, updated_at: :desc) }
  scope :by_name, -> { order(:name) }
  scope :supplier_seeded, -> { where.not(seed_supplier_id: nil) }
  scope :user_created, -> { where(seed_supplier_id: nil) }

  # Methods

  # Seeded lists mirror the supplier account and are view/use-only:
  # nobody edits their contents in EnPlace (the sync would overwrite it).
  def supplier_seeded?
    seed_supplier_id.present?
  end
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
    items = order_list_items.includes(product: { supplier_products: :supplier })
    all_supplier_ids = items.flat_map { |i| i.product.supplier_products.map(&:supplier_id) }.uniq
    suppliers = Supplier.active.where(id: all_supplier_ids)

    suppliers.each_with_object({}) do |supplier, totals|
      total = items.sum do |item|
        sp = item.product.supplier_product_for(supplier)
        sp&.current_price ? sp.current_price * item.quantity : 0
      end
      available_count = items.count { |item| item.product.available_at?(supplier) }

      totals[supplier] = {
        total: total,
        available_items: available_count,
        missing_items: items.size - available_count
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

  # Copies never carry seed_supplier_id — duplicating a supplier list is how
  # a chef gets an editable copy of it.
  def duplicate!(new_name = nil, for_user: user)
    new_list = OrderList.create!(
      user: for_user,
      organization: organization,
      location: location,
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

  private

  def set_organization_from_user
    self.organization_id ||= user&.current_organization_id
  end
end
