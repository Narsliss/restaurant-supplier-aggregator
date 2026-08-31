# PRD: Savings Reporting — One Definition

- **Status:** Shipped to production 2026-08-31 (`d48c65c..21a393e`, 10 commits)
- **Date:** 2026-08-31
- **Owner:** CJ Moutinho
- **Related memory:** `project_savings_reporting_overhaul.md`, `reference_price_audit_methodology.md`, `feedback_never_mutate_matched_lists.md`
- **Supersedes:** the mid-session proposal artifact, which recommended a *median* benchmark that was overruled — see §4.

---

## 1. Summary

EnPlace displayed three figures called "savings", computed three different ways, none of which reconciled. This replaces all of them with one definition in `Orders::SavingsCalculator`, and makes every reporting surface read it.

Alfios' dashboard moved from **$5,163.80** to **$8,250.65 realized / $3,916.78 left on the table** — higher, and traceable line by line.

---

## 2. Problem

Three numbers, three definitions:

| Surface | Compared against | Priced | State |
|---|---|---|---|
| Dashboard tile | dearest peer | frozen at order time | unit-aware, but fed bad data |
| Best Deals table | raw `MAX(current_price)` | today | **no unit conversion at all** |
| Missed savings | cheapest peer | today | unit-aware |

On Alfios that read $5,257 / $4,052 / $2,801 for the same sixty orders. The page conceded it in its own tooltip: *"the rows below … won't add up to this."*

Underneath sat a data defect. Sysco bills catch-weight items at a rate **per pound**; the label reached `SupplierProduct` but not the list rows the comparison reads. A 16 lb case of pork tenderloin quoted at $3.16/lb was read as a $3.16 case — and because `cheapest_supplier` drives order routing, orders were being routed on phantom prices.

---

## 3. Goals / Non-goals

### Goals
- One definition behind every savings figure.
- Realized and missed are two halves of one calculation, always summing to the market spread.
- Refuse to claim rather than guess when a comparison cannot be made honestly.
- Publish coverage beside every total.
- Correct order routing that was selecting suppliers on mis-read units.

### Non-goals
- Changing what is sent to a supplier at submission. Nothing here touches the payload.
- Reconstructing history. What alternatives cost months ago is unrecoverable.
- Mutating chef-curated matched lists. `ProductMatch` is never written to.

---

## 4. The definition (decided, after two reversals)

```
realized = (dearest comparable peer - what you paid) x quantity bought
missed   = (what you paid - cheapest peer)           x quantity bought
```

**Benchmark = the dearest comparable peer.** Carmin's call, on the argument that decided it: `realized + missed` always equals the full market spread, so the chef's choice only decides how a fixed opportunity is split. A middle pick earns both. **Median breaks that invariant** — buy the median and you earn nothing despite having avoided every dearer option.

Rejected alternatives:

- **Median peer** — lands at 18.6%, closest to Alfio's ~15% hand estimate, but creates dead zones where neither half fires.
- **Next-best peer** — under-rewards exactly the behaviour the product exists to drive.
- **The chef's own prior price** — dead on the data: Alfios switched suppliers **once in 104 repeat purchases** and pays *more* than before (net −$199.65). It would display a negative number.

### Guards, each earned from a row that read wrong

| Guard | Value | Why |
|---|---|---|
| Pack band | 0.6×–1.67× | A retail pound is not an alternative to a 36 lb case. Unbanded, commodity butter compared against Vermont Creamery cultured butter and a single 1 lb pack claimed **$449.70 on a $180 purchase**. |
| Spread gate | 6× | Past this the cheapest and dearest are not the same product. |
| Paid floor | 0.5× cheapest | A real negotiated price is kept; paying under half of every peer means the match or the unit is wrong. |
| Unit/pack dimension | must agree | A ribeye listed `1x4-5 PC` at $18.35/LB parses to *pieces*; converting anyway invented a $5.16 case — cheaper than the raw price, and cheap enough to win routing. |

**Declined lines are excluded, not scored zero.** A smaller number we can stand behind beats a bigger one we cannot.

---

## 5. Where comparisons come from

`ComparisonCandidate.peers_for` draws on three sources, deduped, same-supplier peers dropped:

1. **Product spine** — `supplier_products.product_id` (live).
2. **Chef curation** — `ProductMatch` (live). *This was missing and was the single biggest win:* 885 of Alfios' 905 cross-supplier pairings lived only here and were invisible to the calculation. Adding it took coverage **39% → 67.5%** and realized **$3,372 → $8,458**. Rejected matches are excluded — the chef said no.
3. **Automatic basket candidates** — `Catalog::BasketCandidateMatcher`, rebuilt nightly at 07:00.

The existing Claude baseline (`db/baseline/claude_baseline_groups.json`) does **not** help: of Alfios' 203 ordered products, 8 appear in it and **0** gain a peer. It matched the *catalog*, not the *basket* — near-disjoint sets. Hence the basket-targeted matcher.

`UnitOverride` (chef-set pack weights) now reaches the calculation. It feeds comparison only — never raw pricing — so ordering stays immune by construction. **A supplier-stated weight always outranks a chef-set one.**

---

## 6. Ordering impact

This is the part that required review. `aggregated_list_order_service.rb` reaches the changed code through two doors:

- **line 128** `cheapest_supplier` → *which supplier lands in the cart*
- **line 146** `estimated_total_price` → `order_items.unit_price` → `expected_price` in `build_cart_items` → gates `verify_cart_matches!`

**Both were wrong before this change.** A phantom $2.26 Sysco case beat a real $100.60 one and won routing; the same $2.26 went out as `expected_price` against a supplier billing ~$150, which is a false price-changed halt waiting to happen.

Measured on production before shipping: **19 list rows** change their comparison price; **up to 25 products** could route to a different supplier. All Sysco and US Foods catch-weight proteins and cheeses; enumerated and reviewed row by row.

Four specs in `aggregated_list_order_service_spec.rb` pin both doors and **fail without the change**, reproducing the exact production symptom.

**Submission itself is untouched** — placement, the scrapers and `PlaceOrderJob` never call any of the new code, verified by grep.

---

## 7. Reporting surfaces

- **Dashboard tile** — `Order#recalculate_savings!` writes `savings_amount` and the new `missed_savings_amount` together, from one pass. Written separately they drift.
- **Best Deals** — migrated off the raw `MAX(current_price)` onto `#scored_lines`. It had been comparing a 5 lb bag of peeled garlic against a 20 lb case *from the same supplier* and calling the $495 difference a saving.
- **Missed savings** — **deliberately not migrated.** It prices the peer's *rate* against the quantity bought and ignores the peer's case size; *"does not let the peer's own case size change the comparison"* is a documented decision with specs behind it, and the pack band would silently overturn it. **This is the one remaining divergence** and should be settled on purpose.
- **Explainer** — `app/views/reports/_savings_explainer.html.erb`, collapsed by default, states the rules in a chef's own terms plus coverage. Five specs pin the wording so it cannot drift from the code.

---

## 8. Historical data

`rake savings:recompute` re-derives both figures. Dry run unless `APPLY=1`. Applied to all 67 orders on 2026-08-31; pre-recompute values snapshotted to `/tmp/savings_snapshot_20260831.txt`.

Recomputing uses **today's** prices — Carmin's call, accepting the drift to avoid maintaining a second legacy basis.

---

## 9. Parser fixes shipped alongside

| Pack | Was | Now |
|---|---|---|
| `1 1/9 BUSH` | 0.111 bushel | 1.111 — the mixed-fraction regex required a hyphen |
| `20-22 EA` | 440 apples | 21 — for counts the **separator** decides: every small slash pack in production is a real multiplier, a hyphen is a size range |
| `12x5#-UP`, `24x8OZAVG` | not catch-weight | catch-weight — separator tolerance |
| `8x7-10# LB` | not catch-weight | catch-weight — weight ranges, anchored on multiplier ≥ 2 and no `PC` |

Blast radius: 6 list rows, all produce counts, all previously winning routing on an inflated count that made them look cheap per unit.

---

## 10. Known open items

1. **Rate reads 30.5%; Alfio estimates ~15%.** Unresolved. Worst-peer on volatile produce is the mechanism — a pepper line claimed $173.50 on $178.50 spent because the dearest peer was $52.80/bu when $36.62 was available. The lever is the **spread gate**, not the benchmark.
2. **Six mislabelled products** where the supplier asserts `CS` and it is wrong — 5 Sysco, 1 PPO (`BEEF FEMUR BONE`, confirmed per-pound by two peers at $3.64 and $5.68/lb). Sysco is dormant; the PPO item has never been ordered. A plain data fix is overwritten nightly, so a durable fix needs pinned corrections or a chef-facing unit control.
3. **No end-to-end order** has exercised the changed routing.
4. **Coverage is 67.5%** of spend. The remainder is single-source or unmatched.
5. **Zero of 314 automatic candidates have been reviewed** by a chef.

---

## 11. What did not work, and why

Recorded so nobody rebuilds them:

- **A $/lb plausibility floor.** Water at $0.19/lb is real; Parmigiano at $0.22/lb is not. Onions, flour and carrots sit in the same band as the phantoms.
- **An outlier guard on `cheapest_supplier`.** It flags the *honest* row when the peer is the broken one — $32.29 for 4,000 multifold towels is correct; the peer at $3.76 *per towel* is not.
- **Treating `AV` as catch-weight.** `SMITHFIELD PORK BONE BRISKET 1x30# AV` is genuinely a case price ($1.05/lb); `SARTORI PARMESAN 4x5LB AV` is genuinely per-pound. Same supplier, same marker, opposite meaning.

**The pack string does not determine the price basis.** A peer-fit test — does reading this as per-pound fit its peers better than reading it as a case? — identifies the real ones well (Parmigiano $17.74 against peers at $16.13; femur bone $4.65 against $4.66) but produces false positives wherever peer data is itself corrupted. It is a good **detector** and a bad **auto-fixer**, and is the basis for a future confirm-or-reject queue.
