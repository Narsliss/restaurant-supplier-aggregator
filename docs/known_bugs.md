# Known Bugs (surfaced by RSpec suite)

These bugs were uncovered while building out the test suite (April 2026).
Each has a `skip`'d spec pinned to it so it'll go green once the fix lands.

---

## 1. PlaceOrderJob rescue-hazard shadows `discard_on RecordNotFound`

**File**: [app/jobs/place_order_job.rb:11-53](../app/jobs/place_order_job.rb#L11)

**Symptom**: When a job runs against an order that has been deleted between
enqueue and execution, the job dies with `NoMethodError: undefined method
'update!' for nil` instead of being discarded cleanly.

**Root cause**: The bare `rescue => e` at line 47 catches
`ActiveRecord::RecordNotFound` (a `StandardError`) before `discard_on
ActiveRecord::RecordNotFound` (declared at line 9) can fire. The rescue body
then calls `order.update!(...)`, but `order` is `nil` because `Order.find`
raised before assignment.

```ruby
def perform(order_id, options = {})
  order = Order.find(order_id)   # raises RecordNotFound; assignment never happens
  ...
rescue => e
  order.update!(status: "failed", error_message: e.message)  # NoMethodError
  raise
end
```

**Impact**: This is the exact "rescue corrupts state on programming errors"
hazard already documented in `memory/project_place_order_job_rescue_hazard.md`.
Beyond missing orders, *any* programming error inside `perform` (e.g., a typo,
a nil reference, a refactor regression) lands in this rescue and writes
`status: failed` against the order — turning bugs into mutated production data.

**Suggested fix**:
```ruby
rescue ActiveRecord::RecordNotFound
  raise # let `discard_on` handle the missing-order case
rescue => e
  Rails.logger.error "[PlaceOrderJob] Order #{order_id} failed: #{e.message}"
  order&.update!(status: "failed", error_message: e.message)
  raise
end
```

Two changes: (1) re-raise `RecordNotFound` so `discard_on` can fire, and
(2) safe-navigate `order&.update!` so a `nil` order can never blow up the
rescue body.

**Pinned spec**: `spec/jobs/place_order_job_spec.rb` —
`describe 'discard on missing order'` (currently `skip`'d).

---

## 2. PreOrderValidationService references nonexistent OrderListItem#supplier_product

**File**: [app/services/orders/pre_order_validation_service.rb](../app/services/orders/pre_order_validation_service.rb)
(lines 100, 133, 151, 189, 274, 278)

**Symptom**: Every call to `PreOrderValidationService#validate!` and
`#quick_validate` raises `ActiveRecord::AssociationNotFoundError: Association
named 'supplier_product' was not found on OrderListItem`. Because
`Orders::OrderPlacementService#run_pre_order_validation` wraps the call in a
swallowing `rescue StandardError => e` that returns `{ proceed: true }`,
**thorough pre-order validation is silently disabled in production today** —
no stock, price, order-minimum, or delivery checks ever run before placement.

**Root cause**: `OrderListItem` has `belongs_to :product`, not
`belongs_to :supplier_product`. The service treats `item.supplier_product` as
if it were a real association.

**Affected lines**:
- `:274`: `order_list.order_list_items.includes(:supplier_product)` — raises on materialization
- `:100`, `:133`, `:151`: `product = item.supplier_product`
- `:189`: `order_items.map(&:supplier_product)` (in `validate_cached_prices!`)
- `:278`: `item.supplier_product&.current_price` (in `order_total`)

**Suggested fix**: The canonical pattern in this codebase is
`item.product.supplier_product_for(supplier)` — see [app/models/order.rb:284](../app/models/order.rb#L284)
and [app/models/order_list_item.rb:36](../app/models/order_list_item.rb#L36).

1. Add a private helper:
   ```ruby
   def supplier_product_for(item)
     item.product&.supplier_product_for(supplier)
   end
   ```
2. Replace `item.supplier_product` with `supplier_product_for(item)` at all
   six call sites listed above.
3. Change the eager-load to `order_list.order_list_items.includes(product: :supplier_products)`
   so `Product#supplier_product_for` can hit the preloaded association
   without N+1.

**Impact priority**: HIGH. Beyond the silent disable, the swallowing rescue
in `OrderPlacementService` returns `proceed: true` even when validation
genuinely failed — so a fix to one without the other could surface latent
errors. Consider both together.

**Pinned specs**: `spec/services/orders/pre_order_validation_service_spec.rb` —
6 specs covering credentials, stock, prices, order minimum, delivery, and
2FA paths (all currently `skip`'d).

---

## 3. PreOrderValidationService calls a missing OrderListItem#mark_unavailable!

**File**: [app/services/orders/pre_order_validation_service.rb:110](../app/services/orders/pre_order_validation_service.rb#L110)

**Symptom**: When the scraper reports an item is out of stock,
`validate_stock_availability!` calls `item.mark_unavailable!(...)`. But
`OrderListItem` defines no such method — neither does `OrderItem`. This is
also rescued by the same swallowing rescue described in bug #2, so the
NoMethodError never surfaces; the OOS item just isn't recorded as
unavailable.

**Latent until bug #2 is fixed**: the broken `:supplier_product` reference
(bug #2) prevents this code path from ever executing today, so this is a
hidden failure mode. Once #2 is fixed and stock validation runs for real,
this will start blowing up.

**Suggested fix**: Either (a) implement `mark_unavailable!` on
`OrderListItem` (or the relevant model), or (b) replace the call with the
existing pattern — set a status/note on a real OrderItem record once the
service is refactored to operate on real order items.

**Pinned spec**: none (covered indirectly by the bug-#2-pinned stock spec).

