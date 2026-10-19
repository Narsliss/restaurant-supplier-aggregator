# Build plan: out of stock, all six suppliers (checkout + morning stock)

**Date:** 2026-10-19 · **Status:** PLAN, waiting for Carmin's approval. Nothing below is built except Step 0. · **Order placement:** most steps touch it. Each step states its ordering impact. Every step must fail closed and submit nothing on doubt.

Sources (same worktree): `docs/fix-cw-out-of-stock-message.md` (order 483 and the checkout audit A/B/C) and `docs/morning-jobs-audit.md` (morning jobs, live probes §9).

## The two problems

1. **At checkout:** when a supplier won't take an item, the WHOLE order stops and the chef is told which item and why (never ship short, Oct 3).
2. **Before checkout:** the app shows what's out of stock, so the chef isn't surprised at checkout. Today that data is missing, stale or wrong at every supplier.

## Risk order

| # | Supplier / area | Why here |
|---|---|---|
| 0 | Chef's Warehouse checkout message | Built (order 483). Waiting for commit. |
| 1 | **US Foods** | Can **ship short silently**: no line check, a failed cart write falls back to our own copy, and submit can "confirm" with our own id. Stock is never read. |
| 2 | **Premiere Produce** | Can **ship short silently**: no line check, and a failed availability read marks everything in stock. |
| 3 | **Stale "out of stock" flags and the morning stock run** (all six) | ~2,600 wrong flags today hide items from search and skip them as cheapest. |
| 4 | **Sysco, What Chefs Want, Performance**: changed lines and vague messages | Inferred ship-short paths (quantity echo, unit swap, same-count swap) and dropped reasons. |
| 5 | **Screens and alerts** (all suppliers) | Make every stop obvious on a phone, with one-tap removal. |

Each phase is its own commit and needs Carmin's yes at that moment. Pushes and deploys are separate yeses. Migrations need a worker restart after deploy.

---

## Step 0: Chef's Warehouse checkout message (BUILT, uncommitted)

CW's `validationMessages` become named failed items. An all-missing cart mismatch names the items and flags them red with a Remove button. "Leftover" wording is used only for extra lines. The CW cart is emptied when an order stops. 1,770 specs green. See `fix-cw-out-of-stock-message.md`.

---

## Phase 1: US Foods (highest risk)

**1.1 Cart truth** (`us_foods_api.rb:500-508`, `us_foods_scraper.rb:1207-1215, 2241`)
- A failed cart write (`put_json` → nil) **raises**. Never fall back to the local copy.
- A failed `clear_order` (nil, or lines still there) **raises**.
- Add `verify_cart_matches!`:
  - re-GET the open order (`GET /order-domain-api/v1/orders`, which `clear_cart` already uses);
  - compare every line's product number and `unitsOrdered`/`eachesOrdered` with the order;
  - a missing line becomes a named failed item, and an extra or changed line becomes a mismatch;
  - on any stop, empty the USF order.
- Keep `confirms_lines_before_submit?` **false** for USF until 1.3 lands, so the cached stock check stays on.
- *Ordering impact:* adds a gate before submit, never removes one. A USF order that today would submit after a failed cart write now stops and names the reason.

**1.2 Submit truth** (`us_foods_scraper.rb:2204-2212`, `us_foods_api.rb:762-766`)
- ~~Count the order as placed only with a `tandemOrderNumber`~~ **Corrected while building:** US Foods never returns a tandem number at submit. All 22 live orders are confirmed with US Foods' orderId; order 482 answered `SUBMITTING`.
  - Placed = OUR orderId with a status past IN_PROGRESS.
  - Anything else is read back: still in the cart → "not placed"; found submitted → confirmed; else `OrderUnconfirmedError`.
  - The orderId is US Foods' own id, so it is a valid confirmation. See `fix-usf-order-checks.md`.
- A submit timeout or 5xx becomes `OrderUnconfirmedError` (`pending_manual`, can't be retried), never `failed`. That removes the double-order risk.
- *Ordering impact:* an ambiguous submit becomes "check before reordering" instead of a fake confirmation or a retryable failure.

**1.3 Live stock at order time** (probe §9: products v2 `inventory` block)
- Implement `check_stock` for USF. Pre-order validation already uses `check_stock` when a scraper has it (`pre_order_validation_service.rb:112-140`).
- One batched `POST /product-domain-api/v2/products` for the order's SKUs (50 per call) reads `casesOnHand − casesOnReserve − casesWaitlistReserve` (eaches for piece lines).
- **DECIDED (D1, Oct 19): warn at the price check, block only discontinued. BUILT**, see `fix-usf-order-checks.md` 1.3. It is done in the price check (`scrape_prices`), not `check_stock`, so nothing blocks at submit.
- *Original question:* when on hand is 0, **block** the order (name the item), or **warn** and let the chef submit? USF can fill from inbound purchase orders by the delivery date; `summary.poDates` shows ORDERED POs. Recommendation: warn, with the inbound date if there is one. Block only when the product is discontinued (1104), gone (1102) or proprietary (1106).
- After 1.1 and 1.3, USF gets `confirms_lines_before_submit? = true`, so the stale cached flag no longer blocks USF orders.
- *Ordering impact:* changes what can stop a USF order at pre-validation (stale flags out, live stock in). Shadow first: log what it would say for a week and compare with the USF exception emails after allocation.

**1.4 Piece orders** (`us_foods_api.rb:480-482`)
- Send `eachesOrdered` for PC lines, or refuse PC at USF with a clear message until it's verified live.
- *Ordering impact:* stops a 3-PC order going out as 3 cases.

**1.5 Price errors at checkout** (`us_foods_scraper.rb:2165-2170`)
- A line with error 1102/1104/1106, or with no price, becomes a named failed item ("US Foods has discontinued this item").

**1.6 Morning data fixes**
- Read the products v2 `inventory` block in the 6 AM import (zero extra calls), into the Phase 3 stock fields.
- Refresh the USF token during long runs.
- A product that was discontinued and comes back gets `in_stock` restored.

**Specs:** failed PUT raises; missing, extra and changed lines; cart emptied on stop; submit without a tandem number → unconfirmed; timeout → unconfirmed; `check_stock` reads the inventory block; PC sends eaches; 1104 names the item.

---

## Phase 2: Premiere Produce

**2.1 Line check:** call the app's own `OrderSummary_ValidateOrder` on the draft we are about to submit (`premiere_produce_one_api.rb:311`).
- It returns every line (`pack_quantity_at_order`, `external_item_id`), plus `alerts`, `can_place_order` and `missing_essential_item_ids`.
- A missing line becomes a named failed item. A changed line becomes a mismatch. `can_place_order: false` or any alert stops the order, quoting `alert_message`.
- Also compare the `updateCart` reply lines (already returned, never read).

**2.2 Rejected cart update:** keep our SKU and name (today the item name goes in the SKU field) and show PPO's error text instead of "API rejected".

**2.3 Availability read:**
- A failed or missing availability call means **unknown**, never "in stock".
- Use the DST-safe delivery time (`ppo_delivery_time`) instead of a fixed `04:00Z`; this breaks Nov 1 otherwise.
- `SPECIAL_ORDER` is shown as such, not as out.
- PPO reported no `OUT_OF_STOCK` in any probe, so the PPO "out" rule stays off until one is seen.

**2.4** `clear_cart` fails closed. The order total multiplies by quantity.

*Ordering impact:* adds a gate before submit, and `can_place_order: false` stops orders PPO itself would reject. The cached stock check stays on for PPO until 2.1 is live.

**Specs:** dropped line named; quantity change is a mismatch; an alert stops the order; a failed availability call changes nothing; DST date.

---

## Phase 3: Morning stock + stale flags (all six)

**3.0 Foundation**
- **Record the evidence.** New columns on `supplier_products`: `stock_signal` (the raw supplier value), `stock_checked_at` and `stock_source` (job and login). No new rows.
- **Per-supplier rule.** Each scraper maps its raw value to in / out / unknown. The importer writes "out" only on a definite out, "in" only on a definite in, and nothing on unknown. This replaces the blanket "only mark in" rule (042aa34) supplier by supplier.
- **Shadow mode.** Each supplier records signals and "would flip" counts for two mornings before it can change `in_stock`.
- **Morning stock report.** Per supplier: in-use items checked today, how many are out, and any failure or short run. **Email Carmin only on failure, a short run or no run.** The Operations page shows the same; "syncing" older than an hour shows red with its age.
- Log which login every morning job used. Fix the wrong `recurring.yml` times.

**3.1 Per supplier (signals confirmed by probes, Oct 19)**

| Supplier | Source | Out when | Extra calls |
|---|---|---|---|
| US Foods | products v2 `inventory` (Phase 1.6) | available cases ≤ 0 (shown, not blocking, per D1) | 0 |
| Chef's Warehouse | daily full category crawl, **paged by page number up to CW's total** (the token is unreliable on every login) | count == 0 | ~300 pages, ~17 min |
| Performance | `IsOutOfStock` from the existing 6 AM search (99% coverage) | `IsOutOfStock == true` | 0 |
| What Chefs Want | daily full browse crawl (works weekly today) | `unavailable == true` (`isOutOfStock` only with WCW's real delivery date) | ~140 pages |
| Sysco | existing SearchProducts | `O` / phased out / not orderable; **D, R, N stay in**; unlisted → discontinued path, not "out" | 0-30 |
| Premiere Produce | availability list | none seen yet | 0 |

**3.2 Clearing the ~2,600 stale flags**
- After each supplier's shadow run, reset "out" to "in" **only where that supplier says the item is available today**:
  - WCW 1,492;
  - CW 652;
  - USF 242;
  - Performance 53 (accurate today);
  - Sysco 189 (unlisted, so these become discontinued, not "in").
- Report the counts before writing.
- **Carmin decides (D2):** reset everything the supplier contradicts at once, or only items on lists first?

*Ordering impact:*
- No cart or submit gate changes.
- What chefs see changes: labels, the review-page warning, add-item search, and the cheapest/default supplier, split and minimum suggestions.
- For US Foods and PPO, cached "out" blocks orders until Phase 1 and 2 add their line checks. Turn on their "out" flags only after that, or under D1's warn rule.

**Specs:** definite out / in / unknown per supplier; unknown keeps the old value; a failed read changes nothing; a short crawl is detected and alerted; shadow writes no `in_stock`; the stale-flag reset only touches items the supplier confirms.

---

## Phase 4: Sysco, What Chefs Want, Performance (changed lines and dropped reasons)

- **Sysco:**
  - compare the echoed `qty`/`soldAs` with the order, and submit the quantity we asked for, never the echo (`sysco_scraper.rb:639-664`);
  - attach GraphQL errors to their SKU;
  - whole-cart failures become named `ItemUnavailableError`;
  - after submit, require the order to be found, not OPEN, with the expected line count, or → unconfirmed.
- **What Chefs Want:**
  - keep the GraphQL error text per item as the reason (`what_chefs_want_api.rb:508-511`);
  - when a product has several variants, require the exact variant (unit) in the cart check;
  - a submit timeout or non-2xx → check `get_orders`, else unconfirmed.
- **Performance:**
  - compare `TotalOrderPrice` and the echoed lines, not just counts;
  - re-read TotalLines after each single-line add, so the item that didn't take is named;
  - show `RejectedMessage`;
  - `clear_cart` fails closed;
  - a submit timeout → unconfirmed.
- **All:** cart-mismatch messages name each line ("cart had 1 of X, you ordered 2"; "had it as a case, you ordered pieces").

*Ordering impact:* adds gates and better reasons, and removes the double-order retry path. Nothing is loosened.

---

## Phase 5: Screens and alerts (all suppliers)

- **Mobile order page:**
  - refused items sorted to the top;
  - "−" at quantity 1 becomes Remove (confirm tap), or every line gets Remove on a reopened order (the chef couldn't drop the walnuts);
  - pre-validation stops flag their items red too (`run_pre_order_validation` has the item ids).
- **Desktop order page:** refused items red with the reason (today a grey "Failed" badge).
- **Batch progress:** Edit & Retry for `pending_review` as well as `failed`.
- **Messages:** the B-table rewrites in `fix-cw-out-of-stock-message.md` ("Not placed. …" plus what to do; no jargon or raw errors).
- **Generic error handler:** an error raised during a LIVE checkout → `pending_manual` ("check before reordering") unless the scraper says nothing was sent.
- **Quantity edits:** rejected while an order is being placed (one landed 0.5 s after Submit on order 483).
- *Ordering impact:* display, plus the live-checkout error → `pending_manual` change, which removes a duplicate-order path.

---

## Decisions Carmin owns (asked one at a time when their step comes up)

- **D1:** US Foods item with 0 on hand at submit: warn (recommended, with the inbound date) or block?
- **D2:** stale-flag reset: everything the supplier contradicts at once, or list items first?
- **D3:** commit Step 0 now?

## Outside this plan (found on the way, needs Carmin separately)

- **Performance:** all four org-7 logins have ONE customer, AJM D'ORO (33902404). The login EnPlace attaches to alfios placed order 335 (Sep, "alfios") on D'oro's account (inferred).
- **8 AM guide sync:** one login per organization, picked by a tie-break that flips daily. 35 lists stuck "syncing". Errors swallowed and runs logged "completed". The daily health email is never sent.
- **The weekly CW "deep" crawl** has silently fetched 512 of ~15,900 items on some Sundays (fixed by 3.1's page-number paging).
