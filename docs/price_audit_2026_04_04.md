# Price Audit Report — April 4, 2026

## Fix: Guard `inferred_price_unit` for case-pricing suppliers

### Root Cause

`inferred_price_unit` detects variable-weight patterns (`LB AVG`, `LB+`, `#avg`) and treats
the stored price as per-lb. This works when the SLI price IS per-lb (from order guides that
return per-unit prices), but breaks when the SLI has a case price:

1. **Catalog-search SLIs** — `CatalogSearchService` creates SLIs with `price: supplier_product.current_price`, which is the case price for case-pricing suppliers.
2. **"- Case" suffix items** — WCW pack sizes like `15 LB AVG | CATELLI BROS - Case` are case-priced.
3. **WCW accounts returning case prices** — Some WCW accounts return case prices in their order guide (pack_size has `LB AVG` but no `- Each` suffix). The same WCW product on a different account shows the per-lb price with `- Each`.

### Changes Made to `app/models/supplier_list_item.rb`

**Guard 1: Catalog-search + blank price (existing guard enhanced)**
For `case_pricing` suppliers, skip inference when price is blank (falls back to SP) or source is `catalog_search` (price copied from SP).

**Guard 2: PPO "Case -" prefix (existing)**
`return nil if pack_size =~ /\ACase\s*-/i`

**Guard 3: "- Case" suffix (new)**
`return nil if pack_size =~ /-\s*Case\b/i`

**Guard 4: LB-based patterns without "- Each" (new)**
For case-pricing suppliers with `LB` in pack_size but no `- Each` suffix, skip inference. This specifically handles WCW's two account formats:
- Format with `- Each` suffix: price IS per-lb (inference allowed)
- Format without suffix: price is case (inference blocked)

Does NOT affect Sysco (`#avg`/`#UP` patterns, no `LB`), US Foods (`case_pricing=false`), or PPO.

### Audit Results — Local Database

- **Total SLIs checked:** 2,440
- **Prices changed by fix:** 5 (3 unique items × 2 lists, plus 1 catalog-search)
- **No regressions detected**

### Audit Results — Production Database

- **Total SLIs checked:** 1,640
- **Prices changed by fix:** 6
- **No regressions detected**

| # | SLI | Supplier | Item | Pack | Price | Before | After | Inflation |
|---|-----|----------|------|------|-------|--------|-------|-----------|
| 1 | 6080 | WCW | Veal Short Ribs Catelli Bros | 15 LB AVG \| CATELLI BROS - Case | $112.50 | $112.50/LB ($7.03/oz) | $112.50 case ($0.47/oz) | 15x |
| 2 | 9815 | WCW | Tenderloin Prime Psmo | 5LB UP AVG | $119.75 | $119.75/LB ($7.48/oz) | $119.75 case ($1.50/oz) | 5x |
| 3 | 9817 | WCW | Tenderloin Creekstone Choice 5Up | 6LB AVG | $138.90 | $138.90/LB ($8.68/oz) | $138.90 case ($1.45/oz) | 6x |
| 4 | 9850 | WCW | Pork Boston Butt Boneless | 2/7LB AVG | $40.60 | $40.60/LB ($2.54/oz) | $40.60 case ($0.18/oz) | 14x |
| 5 | 9867 | WCW | Tenderloin Choice 5Up Psmo | 6LB AVG | $135.48 | $135.48/LB ($8.47/oz) | $135.48 case ($1.41/oz) | 6x |
| 6 | 9892 | WCW | Veal Short Ribs Catelli Bros | 15 LB AVG | $112.50 | $112.50/LB ($7.03/oz) | $112.50 case ($0.47/oz) | 15x |

### Regression Checks Passed

| Supplier | Pattern | Items | Result |
|----------|---------|-------|--------|
| US Foods | `LB+` | 3 | Still infer per-lb ($14.65/LB, $18.31/LB) |
| Sysco | `#avg`, `#UP` | 5 | Still infer per-lb ($13.75/LB, $20.95/LB) |
| WCW (list 69) | `LB AVG \| ... - Each` | 4 | Still infer per-lb ($22.58/LB, $23.15/LB) |
| PPO | `Case - N#` | 3+ | Still blocked (nil) |
| WCW (list 69) | `LB AVG \| ... - Case` | 1 | Still blocked (nil) |

### Supplier Pattern Summary

| Supplier | case_pricing | Uses `\|` | Variable-weight format | Price type |
|----------|-------------|-----------|----------------------|------------|
| US Foods | false | No | `LB+` | Per-lb |
| Sysco | true | No | `#avg`, `#UP` | Per-lb |
| WCW (acct A) | true | Yes | `LB AVG \| ... - Each` | Per-lb |
| WCW (acct A) | true | Yes | `LB AVG \| ... - Case` | Case |
| WCW (acct B) | true | No | `LB AVG` (no suffix) | Case |
| PPO | true | No | `Case - N#` | Case |

### Prior Fix (Earlier in Session)

Commit `86b9487` fixed:
1. Removed `N/N LB CS` regex false positive (13 WCW items)
2. Added `Case -` prefix guard for PPO (2 PPO items)
3. Expanded `LB AVG` regex to support `LB UP AVG` (2 WCW tenderloin items)
