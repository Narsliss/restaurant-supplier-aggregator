# Send suppliers only what their own sites send (Oct 19 2026)

**Status:** built and tested, NOT committed, NOT pushed.

## Why

Carmin asked whether EnPlace sends "illegal" or suspicious orders that could make a supplier not want to work with us. A What Chefs Want "order modified" email (order 457, vinegar 1 → 0) prompted the question; that cut was WCW's own fulfillment change. But the check found that our WCW cart lines carried labels WCW's site never sends. Carmin: "if it's not something native to WCW, why are we adding it … why would we want to flag ourselves as something out of the ordinary?"

## What we found (read-only)

**What Chefs Want:**
- Every cart line said where it came from with `sourcePage: "OrderGuide"`, `sourceLocation: "API"`.
- Those values were written into the first WCW client in March (6a0714c), not copied from WCW.
- WCW's public site code (736 script files on its CDN, read Oct 19) has fixed lists of these labels: 34 pages and 66 locations. Neither list has "API". The order guide page sends `"Order Guide"` for both. An item found in catalog search sends `"Catalog"` / `"Catalog Search"`, matching what we captured from WCW's site on Oct 3.
- Order 457 itself was ordinary otherwise: all 11 lines came from the restaurant's own WCW order guide, sent through the same two steps WCW's site uses, under the chef's login.

**Other suppliers, checked for values we made up:**

| Supplier | Value | Verdict |
|---|---|---|
| US Foods | line source `MO` | Native: on US Foods orders delivered Oct 9, 12, 14, 15 and 16, days with no EnPlace order (US Foods' recent orders, read-only). US Foods' own `CD`/`CS` codes appear on rep and customer-service edits. |
| Sysco | order source `WEB` | Native: Sysco's own order list shows `WEB` (order #337 and its split-offs). |
| What Chefs Want | search `source: "catalog_search_carousel"` | Native: in WCW's own code. |
| Chef's Warehouse | bare browser ID `Mozilla/5.0` on the catalog crawl (now ~300 requests each morning) | Not what any browser sends. Now the same full browser ID our other CW requests use. |

## Changed

- `WhatChefsWantApi::SOURCE_ORDER_GUIDE` / `SOURCE_CATALOG_SEARCH`: WCW's own labels.
- Cart lines (create, update, submit) carry "Order Guide", or "Catalog Search" for an item added from the catalog. The scraper remembers which source each line came from.
- `ChefsWarehouseApi` catalog crawl: full browser ID.

## Ordering impact

Only the labels on WCW cart lines change. Items, quantities, prices and the delivery date are unchanged. WCW accepts these as free text; it took "API" without complaint.

## Not changed / open

- **WCW's "added to cart" time:** we stamp every line with the same moment, in seconds. WCW's code passes along whatever its cart line holds. I couldn't find the format it uses, so this is left as is.
- **WCW's price fields:** we send the guide price we showed the chef, which WCW's code does too.
- **Whether suppliers allow ordering this way at all** is a question for each supplier, not the code.

## Specs

`what_chefs_want_checkout_checks_spec.rb`:
- "cart line labels": guide vs catalog search; a line with no source uses the order guide labels.
- "cart line labels end to end": add to cart and submit carry the same labels, and "API" appears in nothing sent.
