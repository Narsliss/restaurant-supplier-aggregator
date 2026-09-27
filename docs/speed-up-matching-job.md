# Speed up the matching job (Sep 27 2026)

## Why
`SyncNewProductsJob` on alfios list 8 took ~10 minutes each time (598 s, 615 s). Carmin: "is there a clear path to [speed it up]?"

## Measured on production (read-only profile, AI off)
- 1,121 rows; 1,011 "new" items re-checked every run.
- **All 1,011 were products this supplier already has on the list** (reached via the product map, another of the supplier's lists, or catalog search). Guide items like these never get a link of their own, so every run treated them as new and only discovered they were duplicates after all the matching passes.
- 0.3 s per item, so ~5 minutes of pure waste per run.
- One `ProductNormalizer.best_similarity` call costs 0.9 ms, and it re-cleaned both names every time: for each new item, every row's name was cleaned again in pass 2, pass 3 and the AI pre-sort.

## Changes (`IncrementalProductMatcherService`, `ProductNormalizer`)
1. **Skip already-listed products up front.** If `[supplier, supplier_product]` is already linked on the list, count it as redundant and skip all matching. Placements made during the run are added to the set, so a second copy in the same run is skipped too. This is slightly safer than before: the old path could put a product into a second row, which the cleanup then had to merge back.
2. **Clean each name once per run.** `normalized(name)` and `tokens(name)` are memoized per run. `ProductNormalizer.best_similarity` is now `best_similarity_of_sets(token_set(a), token_set(b))`, the same arithmetic on precomputed sets, and pass 2, pass 3 and the AI pre-sort use it.

No matching decision changes for genuinely new items, and existing rows are never touched.

## Tests
- `incremental_product_matcher_service_spec`: +3. The skip test fails on the old code.
- `product_normalizer_similarity_spec`: exact score equality on five pairs.
- Full suite: 1,558.

## To verify after deploy
Time "Sync New Products" on alfios list 8 against the ~10 min baseline.
