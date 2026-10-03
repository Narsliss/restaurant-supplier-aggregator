# US Foods: tell the chef when an order changes after it's placed

**Date:** 2026-10-03 · **Status:** built, full suite green (1,718 examples), not yet deployed · **Order placement:** NOT touched. Everything here is read-only against US Foods, after submission.

## Why

Carmin shared the US Foods app view of Alfio's order #332 (delivered Sep 28):
- Champagne vinegar #4336327: "Expected in-stock 9/29", ordered 1 CS, **reserved 0**
- Chevre log #4917936: the same

EnPlace never told anyone. Production data showed **16 US Foods orders checked after submit, 0 exceptions ever recorded**.

## What was wrong (read-only diagnosis against Alfio's live `recentorders`, Oct 3)

1. **We only looked in the first minute.** `CheckOrderExceptionsJob` re-reads the order about 20 seconds after submit, up to 3 times. US Foods allocates later. At submit every line had reserved = ordered; the vinegar and chevre dropped to 0 reserved afterwards.
2. **The parser read `quantityAccepted` as a count.** It's a **true/false** flag. Once it's `true`, `true.to_i` raised. `SupplierExceptionChecker` rescued the error and recorded nothing. The real count is `unitsReserved` (cases) or `eachesReserved`.
3. **US Foods re-files the order under a new id.** #332 was submitted as `1a33fcdd-…` and later appeared as `ff9943c0-…` (tandem 648653). The saved id stopped matching, so a later check couldn't find it.
4. **After delivery US Foods archives the order (`orderStatus: TANDEM_DELETED`) and sets `tandemDeleted: true` on every line.** The parser read that as "Removed by US Foods", so a later check would have reported all 12 lines as removed.

## What changed

- **`UsFoodsExceptionParser`:** reads reserved against ordered, for cases and eaches.
  - Ignores `quantityAccepted`.
  - Treats `tandemDeleted` as "removed" only on an order that isn't archived.
  - Skips abandoned drafts (`DELETED`).
  - Treats `"Y"` as a substitution flag.
  - "Not reserved yet" (`nil`) is not an exception.
- **`UsFoodsScraper#fetch_submitted_order(conf, delivery_date:, skus:)`:** tries the saved id first. Otherwise it picks the order for the same delivery date whose lines overlap ours the most, with at least 60% overlap. It never matches a `DELETED` draft or the `IN_PROGRESS` cart.
- **`SupplierExceptionChecker`:** passes the delivery date and our SKUs, and keeps only exceptions for lines on **our** order (a matched order can carry lines a chef added on US Foods' own site).
- **`UsFoodsExceptionSweepJob`** (production `recurring.yml`, America/New_York):

  | Run | Time | Orders checked |
  |---|---|---|
  | `evening` | 7 PM | delivering tomorrow |
  | `morning` | 5 AM | delivering today |

  Each order is re-checked with `notify: true`, staggered 20 seconds apart. These times are Carmin's starting point.
- **`CheckOrderExceptionsJob` with `notify: true`:** emails the chef and the owner(s) via `OrderMailer#supplier_changed_order` ("US Foods changed your order for Mon Sep 28: 2 items not coming").
  - **Each change is emailed once.** It keeps a cache signature of sku, type and quantity reserved, so the evening and morning runs don't repeat the same email.
  - **A failed send records nothing**, so the next sweep retries.
  - **The first-minute check stays in-app only.** Anything it finds is emailed by the 7 PM sweep.
- **Email:** each item with what changed ("0 of 1 coming"), **Open in US Foods** (`supplier_order_url`, US Foods' orders page), and a link to the order in EnPlace.

## Evidence

- `spec/fixtures/files/usf_recent_orders_2026_10_03.json` holds Alfio's live `recentorders`, captured read-only and trimmed to order and line fields. It has no addresses, drivers or GPS. It contains #332 as re-filed, a shipped order and an abandoned draft.
- Specs:
  - **Parser:** on the fixture it finds exactly the vinegar and chevre, doesn't call archived lines removed, doesn't crash on `quantityAccepted`, and reports nothing for the shipped order or the draft.
  - **Re-filed lookup:** finds the order by id, by date and items, with a few lines added or dropped; rejects the wrong date, low overlap and the draft.
  - **Checker:** passes date and items through and filters to our lines.
  - **Job:** emails the chef and owner, sends once per change, again when something new appears, first minute in-app only.
  - **Sweep:** evening picks tomorrow's orders and morning picks today's, skipping dry runs and failed orders.

## Not done / open

- **Deep link to the specific order:** `supplier_order_url` is US Foods' orders page (`/desktop/order`), not the order itself; the order-detail URL format isn't known yet.
- **When US Foods actually allocates** isn't known. We'll learn from when the evening and morning runs start finding things, and can then move or add runs.
- **The other five suppliers** need the same read-only check of their order-status data first.
