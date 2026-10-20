# Morning stock report: real gaps only, and Sysco list items read

Oct 20 2026. Follows `plan-out-of-stock-all-suppliers.md` (Phase 3, the morning run and its 9:15 AM report).

## Why

The first live morning run (Oct 20) emailed four "problems". Carmin read them and asked whether they were all fine. They weren't all real, and one of them wasn't what it looked like. Prod reads (read-only, Carmin approved each one) showed:

| Supplier | Report said | What it actually was |
|---|---|---|
| Chef's Warehouse | crawl came up short (15,574 of 25,023; short: Supplies) | Supplies has ~19,500 non-food items and stops at the 200-page × 50 = 10,000 per-category limit. Every food category was complete; 96% of list items read. |
| What Chefs Want | crawl came up short (6,501 of 6,675; 12 categories) | 97% with no errors, each category just under the old 98% bar; 99% of list items read. Why WCW's own counts run slightly high is unknown. |
| US Foods | only 612 of 800 list items read (77%) | 88 of the 800 are discontinued. 100 more were reached by the 6 AM run, but US Foods sent no inventory block for them (supplies, paper, chemicals, some drinks; red beets). It read 612 of the 612 items it gives stock for. **False alarm.** |
| Sysco | only 433 of 586 list items read (74%) | 1 discontinued; 10 last seen Sep 27 (only on "Suggestions for you"/"Favorites"); **142 the term search never returned.** The known-SKU refresh after it reprices them but carries no stock. **Real gap**, with no chef impact yet because Sysco has reported no outs. |

A report that fires every morning for known causes stops being read (feedback: quiet success, alert on failure).

## What changed

1. **Crawls record capped categories separately** (`ChefsWarehouseScraper`, `WhatChefsWantScraper`). A category that stops at the page limit with more items left goes in `crawl_stats['capped']` (plus `capped_fetched` / `capped_expected`), not in `short`. **The limit stays at 10,000.** Carmin declined a raise: EnPlace is primarily food ordering, and she doesn't want massive non-food imports.
2. **The import records list items it reached but got no stock for** (`ImportSupplierProductsService#apply_stock_evidence!` → `stock_no_data_ids`). The run summary saves them as `last_stock_run['list_no_stock_data_ids']`, capped at 2,000 ids.
3. **Sysco: stock for list items the crawl missed** (`read_stock_for_unread_list_items!`). This runs inside `import_catalog`, before `finish_stock_run!`. Non-discontinued list items not read by the crawl are looked up with the scraper's `live_stock_for`, the batched item-number search the price check already uses (20 per call; ~8 calls for 142 items). It applies the same evidence rules as the crawl: live = in now, out held for the 25% guard; shadow = in only; off = nothing. Only scrapers with `live_stock_for` run it, and today that's just Sysco. A failure lands in the run's errors, so it's reported.
4. **Report rules** (`MorningStockReportJob`):
   - Coverage leaves out discontinued items and this morning's no-stock items: `checked / (total − no_data) < 85%`.
   - New alarm: the supplier sent no stock for **more than 25%** of list items (min 20). That means the stock reader broke. US Foods' normal is ~14%.
   - Crawl alarm only when a category **failed**, or the crawl fetched **under 95%** of the expected items once capped categories are set aside. Capped categories and small shortfalls become **notes**: grey on the Operations page, never emailed.
   - The Operations page shows "N no stock sent" under the list-coverage numbers.

## Behavior change to watch

- **Sysco list items can now be marked out by the morning run.** Before, 142 of them were never read. The rule is the same as the crawl's: Sysco "O", phased out, or not orderable means out, under the 25% guard. Sysco blocks out items in the order builder, so a real Sysco out now shows up in the morning instead of at the cart check.
- The Oct 20 report keeps its old crawl stats until the next run records `capped`. The first run under the new rules is the morning after deploy.

Expected next morning: no CW crawl alarm (Supplies note), a WCW note if it is still slightly short, US Foods ~100 "no stock sent" and no alarm, Sysco coverage near 98%.

## What did NOT work / wrong turns

- My first explanation, from reading code, was that US Foods' and Sysco's gaps came from the capped shallow import. The prod read showed US Foods reached every item. The supplier just sends no stock for some. Sysco's gap was the term search plus a stock-less refresh. Lesson: check the actual unread items before naming a cause.
- Raising the CW Supplies cap was proposed and rejected (non-food).

## Open items

- US Foods: 88 discontinued items still sit on supplier lists. They may be on stale rotated order guides (see the USF order-guide rotation note). Not touched: never mutate lists.
- Sysco: 10 items last seen Sep 27 on "Suggestions for you"/"Favorites". They're probably delisted, and still counted as unread.
- A FOOD category reaching the 10,000 limit would only show as a grey note. Revisit if one ever appears.
- Why WCW's category counts exceed what it returns is unknown.
- Oct 21: compare the morning's outs with Oct 20's snapshot (`tmp/stock_snapshots/`, git-ignored), which shows how many outs flip back in.
