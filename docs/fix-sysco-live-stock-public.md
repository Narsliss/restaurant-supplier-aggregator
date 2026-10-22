# Sysco stock lookup made public: the Oct 20 Sysco stock reads never ran

**Date:** 2026-10-22 · **Branch:** `sysco-live-stock-public` · **Status:** built and tested, NOT committed, NOT pushed · **Follows:** `fix-morning-stock-report-gaps.md` (item 3) and `fix-morning-sync-at-scale.md`

## Why

The 9:15 AM morning stock report kept emailing about Sysco after the Oct 20 fix that was meant to close the gap. Carmin asked whether to be concerned.

| Morning | Report said |
|---|---|
| Oct 20 (before the fix) | only 433 of 586 items on lists got a stock reading (74%) |
| Oct 22 (fix deployed since Oct 20, 20:02 ET) | only 430 of 585 items on lists got a stock reading (74%) |

The Oct 20 record expected "Sysco coverage near 98%" the next morning. Nothing moved.

**Prod logs (read-only, worker deployment `5e3f57b4`, which carries 163fe1d and 599c445):** the Oct 22 6 AM run logged `Sysco import complete` at 10:27 UTC. It never logged `read stock for list items the crawl missed`, and never logged `list-item stock read failed`. The step returned before doing anything.

## Cause

`Scrapers::SyscoScraper#live_stock_for` was defined below the class's `private` line (`sysco_scraper.rb`, `private` at line 1096). Three callers look for it with `scraper.respond_to?(:live_stock_for)`, and `respond_to?` is false for a private method:

| Caller | When | Effect since Oct 20 |
|---|---|---|
| `ImportSupplierProductsService#read_stock_for_unread_list_items!` | 6 AM catalog run | the ~155 Sysco list items the term search misses got no reading |
| `ImportSupplierProductsService#read_stock_for_list_items!` | called by the guide sync | skipped |
| `ImportSupplierListsService#read_guide_stock!` | 8 AM guide sync | Sysco guide items kept the guide's own orderable flag ("guide:in"/"guide:out"); Sysco's real stock reading never followed it |

**The price check was never affected.** `SyscoScraper#scrape_prices` calls `live_stock_for` from inside the scraper, where `private` doesn't matter. Order-time Sysco stock reads worked throughout.

**Why the specs passed:** every spec for these paths used a stand-in (`double('Sysco', live_stock_for: …)`), which answers `respond_to?` whatever the real class does. No spec used the real Sysco class.

## What changed

1. **`live_stock_for` moved above `private`**, next to `fetch_available_delivery_days` (the other method outside jobs call). The method body is unchanged. Its comment now says why it must stay public.
2. **Five specs that use the real `Scrapers::SyscoScraper`** (allocated, with the private `graphql_search_products` stubbed):
   - `spec/services/scrapers/sysco_scraper_spec.rb` `#live_stock_for`: it is public; it reads only the asked SKUs from one batched search and maps `S` in, `O` out; a SKU the search doesn't return, or a failed batch, stays unknown.
   - `spec/services/import_supplier_products_stock_evidence_spec.rb`: the morning run reads the missed list items with the real scraper.
   - `spec/services/import_supplier_lists_guide_stock_spec.rb`: the guide sync records Sysco's reading (source `catalog`), not the guide's assumed `guide:in`.

All five fail on the previous code (`respond_to?` false, so nothing is read) and pass with the fix. Full suite on the branch's own test database: 2,178 examples, 0 failures.

## Ordering impact

- **No cart, add-to-cart, price check or submit code changed.** The price check already called this method.
- **Sysco list items can now be marked out in the morning**, which was the Oct 20 intent: Sysco "O", phased out, or not orderable means out, under the same 25% guard as the crawl. Sysco blocks out items in the order builder, so chefs see a real Sysco out at 6 or 8 AM instead of only at the order check. In probes Sysco has reported no "O" yet.
- **The 8 AM guide sync makes more Sysco calls:** one item-number search per 20 guide items, per Sysco login (about 30 for a 600-item guide). The 9:15 report flags HTTP 429/403 refusals if Sysco starts rate-limiting.

## Checked on the way

- **Is any other method that app code probes with `respond_to?` private somewhere?** A local runner checked all 19 such names (`verify_cart_matches!`, `confirms_lines_before_submit?`, `submit_sent?`, `reports_live_stock?`, `warn_only_out_of_stock?`, `crawl_stats`, `skip_miss_tracking?`, …) on all 38 scraper, API and client classes. Only `SyscoScraper#live_stock_for` was private. No ordering gate has this problem.
- **Does the method need a fresh login?** No change made. Both callers run right after the scraper's own signed-in work (the crawl, the guide fetch). If the session had lapsed, each batch fails, logs a warning and reads as unknown, and the 9:15 report shows the low coverage.

## Deploy notes

- No migration. An ordinary web + worker deploy.
- **Proof is the next 6 AM run** after deploy: the worker should log `[ImportProducts] Sysco: read stock for list items the crawl missed (N looked up)`, and the 9:15 report should not email about Sysco. Expect coverage near 98%, not 100%: about 10 list items were last seen Sep 27 (on "Suggestions for you"/"Favorites") and are probably delisted.

## What did NOT work / wrong turns

- The Oct 20 fix was checked by specs that used stand-ins, and its expected result was never checked against the next morning's run. The Oct 21 and Oct 22 emails were the first sign. Lesson: a step added to a morning job needs (a) one spec through the real scraper class, and (b) a look at the next morning's log for its own log line.

## Open items

- Confirm the first morning after deploy (log line + no Sysco email).
- The ~10 probably-delisted Sysco list items still count as unread. They should go down the discontinued path (open since `fix-morning-stock.md`).
- Watch the 8 AM Sysco call volume as Sysco logins grow.
- Drop the branch test database once this lands: `dropdb restaurant_supplier_aggregator_test_syscostock`.
