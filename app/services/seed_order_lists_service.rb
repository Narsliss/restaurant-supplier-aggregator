# Onboarding headstart: when a chef connects a supplier, give them an order
# list mirroring what they already order there — a one-time welcome snapshot.
# After seeding, the list is entirely theirs; this service never updates or
# re-seeds an existing list (all later edits happen in EnPlace).
#
# Seed source per supplier, by preference:
#   1. A "recently purchased" list (US Foods recentPurchase feed) — what the
#      account actually ordered.
#   2. Chef's Warehouse's guide id "-1" — CW's own recently-purchased guide,
#      imported with list_type "favorites".
#   3. A single static order guide (What Chefs Want / Premiere Produce One
#      emit exactly one, remote_id "order-guide") — the account's de facto
#      order list.
# Vendor-curated lists (USF monthly OG-*/SL-* guides, Sysco marketing lists)
# are deliberately NOT used: they reflect what the vendor pushes, not what
# the chef buys. Suppliers with no source (currently Sysco) seed nothing.
#
# Safety rails:
#   - Auto-seeding never touches a location that already curates its own
#     (non-seeded) order lists — this is a new-signup headstart, not a
#     retrofit. The chef-pressed refresh (see #refresh) is explicit consent
#     and skips that guard.
#   - Idempotent per supplier+location via order_lists.seed_supplier_id.
#   - Items link through the baseline Product spine; source items without a
#     spine product are skipped (they'd be unorderable through the OrderList
#     path anyway).
class SeedOrderListsService
  attr_reader :credential, :results

  def initialize(credential)
    @credential = credential
    @results = { seeded: false, refreshed: false, list_name: nil, items: 0, skipped: 0, reason: nil }
  end

  # Automatic one-time seed on a location's first list import. Guarded:
  # no-op when already seeded or when the chef already curates lists.
  def call
    return skip(:no_location) unless location
    return skip(:already_seeded) if already_seeded?
    return skip(:location_has_own_lists) if location_curates_own_lists?

    source = seed_source_list
    return skip(:no_seed_source) unless source

    items = seedable_items(source)
    return skip(:no_seedable_items) if items.empty?

    create_seeded_list(source, items)
    results
  rescue StandardError => e
    Rails.logger.error "[SeedOrderLists] Failed for credential #{credential.id}: #{e.class}: #{e.message}"
    results[:reason] = "#{e.class}: #{e.message}"
    results
  end

  # Chef-pressed "Refresh recent orders". Explicit user action, so:
  #   - creates the seeded list if missing (even when the location has its
  #     own curated lists — the chef asked for it);
  #   - otherwise ADDITIVE ONLY: appends recently-ordered products not yet
  #     on the list. Never removes or reorders anything the chef kept.
  # Reads the locally synced supplier lists (refreshed daily at 8 AM) — no
  # live scraping, so this returns instantly.
  def refresh
    return skip(:no_location) unless location

    source = seed_source_list
    return skip(:no_seed_source) unless source

    existing = OrderList.for_location(location).find_by(seed_supplier_id: supplier.id)
    if existing
      append_new_items(existing, source)
    else
      items = seedable_items(source)
      return skip(:no_seedable_items) if items.empty?

      create_seeded_list(source, items)
    end
    results
  rescue StandardError => e
    Rails.logger.error "[SeedOrderLists] Refresh failed for credential #{credential.id}: #{e.class}: #{e.message}"
    results[:reason] = "#{e.class}: #{e.message}"
    results
  end

  private

  def create_seeded_list(source, items)
    name = seeded_list_name(source)

    OrderList.transaction do
      order_list = OrderList.create!(
        user: credential.user,
        organization: organization,
        location: location,
        name: name,
        description: "Your recent #{supplier.name} activity, imported when you connected — edit freely, it's yours.",
        seed_supplier_id: supplier.id,
        seeded_at: Time.current
      )

      items.each_with_index do |sli, idx|
        order_list.order_list_items.create!(
          product: sli.supplier_product.product,
          quantity: sli.quantity.presence || 1,
          position: idx + 1
        )
      end

      OrderListSeedRecord.find_or_create_by!(location_id: location.id, supplier_id: supplier.id) do |r|
        r.seeded_at = Time.current
      end
    end

    results[:seeded] = true
    results[:list_name] = name
    results[:items] = items.size
    Rails.logger.info "[SeedOrderLists] Seeded '#{name}' (#{items.size} items) " \
                      "for location #{location.id} from supplier_list #{source.id}"
  end

  def append_new_items(order_list, source)
    existing_product_ids = order_list.order_list_items.where.not(product_id: nil).pluck(:product_id).to_set
    additions = seedable_items(source).reject do |sli|
      existing_product_ids.include?(sli.supplier_product.product_id)
    end

    max_position = order_list.order_list_items.maximum(:position) || 0
    OrderList.transaction do
      additions.each_with_index do |sli, idx|
        order_list.order_list_items.create!(
          product: sli.supplier_product.product,
          quantity: sli.quantity.presence || 1,
          position: max_position + idx + 1
        )
      end
      order_list.update!(seeded_at: Time.current)
    end

    results[:seeded] = true
    results[:refreshed] = true
    results[:list_name] = order_list.name
    results[:items] = additions.size
    Rails.logger.info "[SeedOrderLists] Refreshed '#{order_list.name}': +#{additions.size} items"
  end

  def supplier = credential.supplier
  def location = credential.location
  def organization = credential.organization || credential.user.current_organization

  def skip(reason)
    results[:reason] = reason
    results
  end

  # "Seeded" means EVER seeded, not "a seeded list currently exists" — the
  # tombstone (OrderListSeedRecord) survives the list's deletion so the
  # automatic path never resurrects a list the chef deleted. The explicit
  # refresh button ignores this and re-creates on demand.
  def already_seeded?
    OrderListSeedRecord.exists?(location_id: location.id, supplier_id: supplier.id) ||
      OrderList.for_location(location).exists?(seed_supplier_id: supplier.id)
  end

  # A location with hand-made order lists is past onboarding — injecting
  # lists there would be mutating a chef's curated world.
  def location_curates_own_lists?
    OrderList.for_location(location).where(seed_supplier_id: nil).exists?
  end

  def seed_source_list
    lists = SupplierList.where(supplier: supplier, organization: organization, location_id: location.id)

    lists.find_by(list_type: 'recently_purchased') ||
      lists.find_by(list_type: 'favorites', remote_list_id: '-1') ||
      lists.find_by(list_type: 'order_guide', remote_list_id: 'order-guide')
  end

  def seeded_list_name(source)
    if source.list_type == 'order_guide'
      "#{supplier.name} Order Guide"
    else
      "Recent #{supplier.name} Orders"
    end
  end

  # Source items in guide order, deduplicated by spine product, skipping
  # items with no spine link (unorderable via the OrderList path).
  def seedable_items(source)
    seen_product_ids = Set.new
    source.supplier_list_items
          .by_position
          .includes(supplier_product: :product)
          .each_with_object([]) do |sli, out|
      product = sli.supplier_product&.product
      unless product
        results[:skipped] += 1
        next
      end
      next unless seen_product_ids.add?(product.id)

      out << sli
    end
  end
end
