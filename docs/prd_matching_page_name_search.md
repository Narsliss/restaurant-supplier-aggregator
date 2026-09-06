# PRD: Name search on the product matching page

**Date:** 2026-09-06
**Status:** Built, dev-verified, not yet committed

## Problem

The matching page (`aggregated_lists#show`) renders every product match card on
one page — the seeded dev list has 813, and real lists are similar. Chefs
reported it is overwhelming to find a specific item they want to match.

## Decisions (Carmin)

- **Desktop / tablet-landscape only.** Matching is not offered on mobile, so no
  mobile treatment.
- **Name-only search.** Not supplier descriptions, SKUs, brands, or pack sizes.
  But matching is word-level: typing "chicken" finds "Blue Farms Chicken
  Pieces"; "breast chicken" finds "Chicken, Breast…" regardless of word order.
- **Filter only.** No "add a product" entry point from the search box or its
  empty state (was offered, declined).

## Follow-up decision (same session): specific search hint text

Several searches can share a screen (nav Price Check, Add-a-Product modal, the
per-supplier pickers in the matching modal), so hint text must name its scope —
no generic "Search products...". Applied: main bar "Search matched
products...", Add-a-Product modal "Search catalog to add a product...",
`searchable_select` grew an optional `placeholder` local and all six call
sites pass "Search <supplier short name> items...", order builder "Search
products on this list...". Nav Price Check already said "Search all
suppliers…". Treat this as the convention for future search boxes.

## What was built

- A sticky search bar (`sticky top-16`, under the h-16 navbar, `bg-brand-stone`
  so cards don't show through while scrolling) above the card list in
  `app/views/aggregated_lists/show.html.erb`, with a clear (×) button and a
  "No products match your search" empty state.
- `data-search-name` (lowercased `ProductMatch#display_name`) on each card's
  **left cell** in `_match_row_left.html.erb` — that cell, not the card root,
  because the rename turbo stream re-renders only the left cell, so the
  attribute stays in step with the visible name after a rename.
- `match_filter_controller.js` extended: the query is split into tokens, every
  token must appear in the name (any order); search combines (AND) with the
  existing Total/Matched/Unmatched stat-card filter; category header counts
  update to the visible count; category groups with no visible rows hide
  (existing behavior, reused). Input debounced 150ms.

## Verified (dev, list 8, 813 products)

- "chicken" → 14 rows, all containing chicken, incl. brand-prefixed names.
- "breast chicken" (reversed order) → 5 rows, all containing both words.
- Unmatched card + "cleaner" → exactly the 3 unmatched cleaner rows.
- Nonsense query → 0 rows + empty state; clear button restores all 813.
- Dark mode: `.dark` overrides restyle the bar (no `dark:` classes used, per
  house convention).
- Request spec added in `spec/requests/aggregated_lists_spec.rb` (search box,
  lowercased `data-search-name`, empty state present).

## What did NOT work / gotchas

- During browser verification one filter check read 0 visible rows for a query
  that should have matched — a stale element ref in the automation after a
  Turbo re-render, not an app bug; re-running deterministically passed.
- `data-search-name` on the card root would go stale after rename (rename
  re-renders only `match_left_<id>`); hence the left-cell placement.
- The sticky wrapper originally had no background; scrolled cards showed
  through its padding. Fixed with `bg-brand-stone` (page ground color).

## Open items

- Search is client-side over the fully rendered page. If page weight itself
  (813 cards server-rendered, no pagination) becomes the complaint, that is a
  separate lazy-rendering/pagination effort — search does not address load
  time.
- Confirmed-section header count (`#confirmed-matches-count`) is deliberately
  untouched by the filter (it's turbo-stream-managed); only per-category
  `data-category-count` spans update live.
