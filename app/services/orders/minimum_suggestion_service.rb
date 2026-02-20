# frozen_string_literal: true

module Orders
  # Suggests products to add when an order doesn't meet the supplier's minimum.
  # Three-tier priority:
  #   1. Recently ordered from this supplier (last 90 days, by frequency)
  #   2. Items on the user's order guides / favorites for this supplier
  #   3. Fallback: cheapest available products from this supplier
  #
  # Non-perishable items (Dry Goods, Canned, Frozen, etc.) are prioritized
  # over perishables (Produce, Meat, Dairy) since they're better minimum-fillers.
  class MinimumSuggestionService
    MAX_SUGGESTIONS = 8

    NON_PERISHABLE_CATEGORIES = [
      "Dry Goods", "Oils & Condiments", "Spices & Seasonings",
      "Canned & Jarred", "Frozen", "Beverages",
      "Paper & Disposables", "Cleaning & Sanitation", "Equipment & Smallwares"
    ].freeze

    def initialize(user:, order:)
      @user = user
      @order = order
      @supplier = order.supplier
      @exclude_ids = order.order_items.pluck(:supplier_product_id)
    end

    def suggestions
      candidates = []

      # Tier 1: Recently ordered from this supplier
      candidates.concat(recently_ordered)

      # Tier 2: From supplier order guides / favorites
      if candidates.size < MAX_SUGGESTIONS
        candidates.concat(from_order_guides(candidates.map(&:id)))
      end

      # Tier 3: Cheapest available (non-perishable only for fallback)
      if candidates.size < MAX_SUGGESTIONS
        candidates.concat(fallback_products(candidates.map(&:id)))
      end

      candidates.first(MAX_SUGGESTIONS)
    end

    private

    def recently_ordered
      recent_order_ids = @user.orders
        .where(supplier: @supplier, status: %w[submitted confirmed])
        .where("submitted_at >= ?", 90.days.ago)
        .pluck(:id)

      return [] if recent_order_ids.empty?

      # Get frequently ordered product IDs (most orders first)
      frequent_ids = OrderItem
        .where(order_id: recent_order_ids)
        .where.not(supplier_product_id: @exclude_ids)
        .group(:supplier_product_id)
        .order(Arel.sql("COUNT(*) DESC"))
        .limit(MAX_SUGGESTIONS)
        .pluck(:supplier_product_id)

      return [] if frequent_ids.empty?

      products = SupplierProduct
        .where(id: frequent_ids)
        .available
        .in_stock
        .with_price
        .includes(:product)
        .to_a

      sort_non_perishable_first(products, frequent_ids)
    end

    def from_order_guides(already_ids)
      credential = @user.supplier_credentials.find_by(supplier: @supplier, status: "active")
      return [] unless credential

      remaining = MAX_SUGGESTIONS - already_ids.size

      products = SupplierListItem
        .joins(:supplier_list)
        .where(supplier_lists: {
          supplier_credential_id: credential.id,
          list_type: %w[order_guide favorites]
        })
        .where.not(supplier_product_id: nil)
        .where.not(supplier_product_id: @exclude_ids + already_ids)
        .includes(supplier_product: :product)
        .limit(remaining * 2) # over-fetch to account for filtering
        .map(&:supplier_product)
        .compact
        .select { |sp| !sp.discontinued? && sp.in_stock? && sp.current_price.present? }
        .uniq(&:id)

      sort_non_perishable_first(products).first(remaining)
    end

    def fallback_products(already_ids)
      remaining = MAX_SUGGESTIONS - already_ids.size
      return [] if remaining <= 0

      SupplierProduct
        .where(supplier: @supplier)
        .where.not(id: @exclude_ids + already_ids)
        .available
        .in_stock
        .with_price
        .joins("LEFT JOIN products ON products.id = supplier_products.product_id")
        .where("products.category IN (?) OR products.id IS NULL", NON_PERISHABLE_CATEGORIES)
        .order(current_price: :asc)
        .limit(remaining)
        .to_a
    end

    def sort_non_perishable_first(products, frequency_order = nil)
      products.sort_by do |sp|
        category = sp.product&.category
        perishable = NON_PERISHABLE_CATEGORIES.include?(category) ? 0 : 1
        freq_rank = frequency_order ? (frequency_order.index(sp.id) || 999) : 0
        [perishable, freq_rank]
      end
    end
  end
end
