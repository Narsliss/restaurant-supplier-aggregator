# Maintains each location's "Supplier Order Lists": an order list per
# connected supplier mirroring what the account orders there. Seeded lists
# are view/use-only in the app (see OrderList#supplier_seeded?) — every sync
# re-mirrors their items from the supplier source, so the daily list import
# keeps them current: items the supplier feed dropped disappear, new ones
# appear, quantities follow the feed. Chefs who want to customize duplicate
# the list into an editable copy.
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

  # Automatic path, run after every list import (daily 8 AM sync included):
  #   - an existing seeded list is re-mirrored so it tracks the supplier;
  #   - otherwise this is the one-time onboarding seed, guarded: no-op when
  #     the list was deleted (tombstone — an owner's delete stays deleted)
  #     or when the chef already curates their own lists.
  def call
    return skip(:no_location) unless location

    if (existing = OrderList.for_location(location).find_by(seed_supplier_id: supplier.id))
      source = seed_source_list
      return skip(:no_seed_source) unless source

      mirror_items(existing, source)
      return results
    end

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

  # Chef-pressed "Refresh recent orders". Explicit user action, so it also
  # creates the seeded list if missing (even when the location curates its
  # own lists, or deleted the seeded one — the chef asked for it back).
  # Reads the locally synced supplier lists (refreshed daily at 8 AM) — no
  # live scraping, so this returns instantly.
  def refresh
    return skip(:no_location) unless location

    source = seed_source_list
    return skip(:no_seed_source) unless source

    existing = OrderList.for_location(location).find_by(seed_supplier_id: supplier.id)
    if existing
      mirror_items(existing, source)
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
        description: seeded_description,
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

  # Make the seeded list match the supplier source exactly: remove items the
  # feed no longer has, add the ones it gained, track quantity and guide
  # order. Safe because seeded lists are view/use-only in the app.
  def mirror_items(order_list, source)
    desired = seedable_items(source)
    # A feed that comes back empty is more likely a bad sync than a cleared
    # account — never wipe the list over it.
    return skip(:no_seedable_items) if desired.empty?

    desired_product_ids = desired.map { |sli| sli.supplier_product.product_id }.to_set
    additions = 0
    removals = 0

    OrderList.transaction do
      order_list.order_list_items.each do |item|
        next if item.product_id && desired_product_ids.include?(item.product_id)

        item.destroy!
        removals += 1
      end

      existing_by_product = order_list.order_list_items.reload.index_by(&:product_id)
      desired.each_with_index do |sli, idx|
        quantity = sli.quantity.presence || 1
        if (item = existing_by_product[sli.supplier_product.product_id])
          item.update!(quantity: quantity, position: idx + 1) if item.quantity != quantity || item.position != idx + 1
        else
          order_list.order_list_items.create!(
            product: sli.supplier_product.product,
            quantity: quantity,
            position: idx + 1
          )
          additions += 1
        end
      end

      order_list.update!(seeded_at: Time.current, description: seeded_description)
    end

    results[:seeded] = true
    results[:refreshed] = true
    results[:list_name] = order_list.name
    results[:items] = additions
    Rails.logger.info "[SeedOrderLists] Mirrored '#{order_list.name}': +#{additions} / -#{removals} items"
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

  def seeded_description
    "What this account orders at #{supplier.name} — kept in sync automatically. Duplicate it to make an editable copy."
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
