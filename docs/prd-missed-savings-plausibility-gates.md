# Missed-savings plausibility gates

**Date:** 2026-09-06
**Trigger:** Carmin flagged three rows on the missed-savings report with implausibly
large swings (screenshot: Roseli mozzarella blend claiming $568.88, Crab Meat Jumbo
Lump $236.52, Mozzarella Curd $126.62).

## What we found

Three rows, three different verdicts:

1. **Roseli mozzarella blend ($568.88) — phantom.** The "cheaper" Sysco quote worked
   out to $0.46/lb for shredded cheese. Sysco quotes catch-weight items per pound;
   items imported before commit `853393b` (2026-08-25, "Read Sysco's per-pound quotes
   as per-pound") have no `price_unit`, so the per-lb rate is read as a whole-case
   sticker and Sysco appears 10–20x cheaper than reality. Priced correctly the Sysco
   item costs ~$66/case vs the $60.93 paid at US Foods — US Foods was already the
   best price and the row should not exist. Same root cause as the **parmesan** row
   (local catalog: `MANTOVA PARMESAN REGGIANO 1/8 | 1x9.5# | $16.09`, plainly per-lb).

2. **Crab Meat Jumbo Lump ($236.52) — phantom, different cause.** The $222.06
   US Foods "alternative" matches `HARBOR BANKS CRABMEAT BLUE SWIMMING LUMP`
   ($221.86 in catalog) — regular lump, not jumbo. USF's actual JUMBO LUMP is
   $320.02, i.e. *more* than the $300.90 paid at Chef's Warehouse. This is a
   product-match grade mismatch; per the no-mutation rule the unmatch is the
   user's call in-product, not a code fix.

3. **Mozzarella curd ($126.62) — real.** USF Grande curd at ~$2.94/lb (correctly
   stored `price_unit=lb`) vs ~$3.99/lb effective at Chef's Warehouse. Legitimate.

## Why the existing gates missed these

The Aug 2026 overhaul's validity gates (`implausible_spread`, `paid_below_market`)
live in `Orders::SavingsCalculator`, used by the dashboard order-line path. The
missed-savings report computes through `ProductMatch#comparable_group` instead,
where the only gates were the `:exact` units verdict and the 5x
`MAX_SAVINGS_MULTIPLE` cap. A mislabeled per-lb price *is* in exact units, and
$51.72 "saved" on a $60.93 case is under 5x — both bad rows passed. In the
calculator itself, `implausible_spread` compares peers against the cheapest rate,
so a **lone** bogus-cheap peer (ratio 1.0 against itself) also passed.

## What changed

1. `ReportsController::MIN_PEER_PRICE_RATIO = 0.25` — `qualifying_lines` now drops
   a line whose peer equivalent cost is under a quarter of what was actually paid.
   0.25 rather than 0.5 because this path compares across pack sizes, where a
   genuine 2–3x rate premium for a small convenience pack is real (the cream-cheese
   spec row at ratio 0.41 must survive; the bogus rows sit at ~0.15).
2. `Orders::SavingsCalculator` gained the mirror of `paid_below_market`:
   `:implausible_peer` when the cheapest peer rate is below `paid_rate *
   MIN_PAID_RATIO` (0.5 — this path is pack-banded, so tighter is safe). Catches
   the lone-bogus-peer case the spread gate structurally cannot.
3. Specs: new examples in `spec/requests/reports_accuracy_spec.rb` and
   `spec/services/orders/savings_calculator_spec.rb`. The existing pork-butt cap
   spec's peer price was raised $5 → $20 so it still reaches (and tests) the
   MAX_SAVINGS_MULTIPLE cap rather than being intercepted by the new floor.

## What did NOT work / dead ends

- Confirming the exact prod rows via `railway ssh` was blocked twice by the
  permission classifier; the read-only diagnostic script is in the session
  scratchpad for Carmin to run directly.
- A pack-heuristic backfill of Sysco `price_unit` (`#`/`AV` in pack ⇒ LB) was
  considered and rejected: false positives would inflate Sysco prices 10–20x the
  other way and distort order routing.

## Open items

- **Data heal:** Sysco items last touched before 2026-08-25 still carry blank
  `price_unit`. The nightly `refresh_known_products` direct-SKU path sets it
  correctly (`price_unit_for` + `isCatchWeight`); verify prod Sysco imports have
  been succeeding since the fix, or trigger a full Sysco SKU refresh. Locally:
  0 of 12,635 Sysco products have `price_unit='LB'`.
- **Crab match:** unmatch USF regular LUMP from the CW Jumbo Lump group
  (user action in-product).
- The gates hide bad rows; they do not fix the underlying Sysco prices used
  elsewhere (e.g., matched-list comparison display still shows the bogus rate
  until the data heals).
