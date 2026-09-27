# Sysco Marketplace and Specialty items removed from EnPlace

**Date:** 2026-09-27 · **Decision:** Carmin · **Status:** built, not yet deployed; the one-time cleanup runs as a dry run first · **Order placement:** TOUCHED — the Sysco cart refuses these items

## Decision

EnPlace is for general bulk ordering. Only Sysco's **own stock** (seller group `LOCAL_SALES`) is imported, shown or ordered. **Marketplace** items (third-party merchants like Dot Foods and Melting Forest, run on Mirakl) and **Specialty** items ("Special Delivery", e.g. Edward Don, seller `SOTF`) come off EnPlace. They leave the catalog, ordering, chefs' **matched lists** and the mirrored **Sysco order guides**.

Removing items from matched lists is an explicit exception, made by Carmin, to the standing rule never to touch chefs' matched lists.

## Why (learned from the first live Sysco order, #337)

- **Sysco splits the order:** at submit, Sysco put the Marketplace items into separate orders, each with its own number (`M…`), total and delivery day. The yuzu arrived Oct 8, not Oct 7.
- **No cancelling:** Sysco's own site won't modify or cancel Marketplace / Third Party / Specialty orders once submitted. Its `allowOrderModification` returns false for those seller groups and shows "Cannot modify Marketplace order". The pineapple was allocated within minutes, and cancelling needs the rep.
- **Other rules in Sysco's code:**
  - Marketplace items "do not count toward your order minimum", so our 15-case check counted 6 cases Sysco ignores.
  - They "are not eligible for returns".
  - They may carry shipping fees.
  - They can't be bought on credit hold or card accounts.

## How Sysco marks them

Every search result and order header has `seller { id name group }`, where `group` is `LOCAL_SALES`, `MARKETPLACE` or `SPECIALTY`. This was confirmed live:

| SKU | Seller | Group |
|---|---|---|
| 4279592 sugar | USBL | LOCAL_SALES |
| 6081093 pineapple | 2011 Dot Foods | MARKETPLACE |
| 5899810 Monin syrup | SOTF (DON) | SPECIALTY |

Sysco search takes the facet `{ id: "SELLER_GROUP", value: "LOCAL_SALES" }`, the one its own site uses. It cut a "pineapple" search from 353 results to 116.

## What changed

- **`supplier_products.supplier_seller_group`** is a new column, filled by the catalog import and by seller lookups.
- **`Scrapers::SyscoScraper`:**
  - `LOCAL_SALES_GROUP` and `third_party_seller?(seller, group)`. The group decides when it's known; otherwise any seller other than the account's own (`USBL`) counts as third party.
  - **Catalog import** searches with the LOCAL_SALES facet, and `parse_search_result` drops any non-local result as a backstop.
  - **Seller lookups** (`search_sellers` / `discover_sellers`) record the group. `price_with_sellers` returns `third_party:`.
  - **Refresh:** a third-party SKU is marked unavailable and discontinued through the import's existing "supplier says it's gone" path, which also clears list prices.
  - **Guide sync (`graphql_get_list_items`)** leaves third-party items out: first by the seller the guide itself names, which doesn't depend on pricing succeeding, then by the lookup. Leaving them out of the sync is what stops a removed item coming back. Before this, the sync re-created, re-linked and reinstated (`record_seen!`) anything still on a chef's Sysco guide.
  - **Cart (`add_to_cart`)** refuses them ("Sysco Marketplace item — not ordered through EnPlace"). `OrderPlacementService` auto-removes them with a note.
- **`Suppliers::SyscoMarketplaceRemoval`** + **`SyscoMarketplaceRemovalJob`** do the one-time cleanup:
  1. **Classify:** every Sysco product with no group is looked up by batched search, 20 SKUs per call, with no cap.
  2. **Report:** product counts by group, matched-list cells and rows affected, guide items and teaser cells.
  3. **Remove** (only when `dry_run: false`):
     - matched-list cells via `MatchedListSupplierRemoval` (audited; cause `supplier_item_removed`, newly added to `MatchItemRemoval::CAUSES`). A row emptied by this is deleted, unless a chef's order list or saved cart still uses it.
     - row image choices pointing at removed products are cleared.
     - the Sysco guide items for these products (matched by link or SKU) are deleted.
     - their teaser cells and comparison peers are deleted.
     - the products are marked discontinued and out of stock. They're kept, not deleted, so order history still works.

## Rollout

1. Deploy.
2. Run `SyscoMarketplaceRemovalJob.perform_later(<cred id>, dry_run: true)` on prod and read the `[SyscoMarketplaceRemoval] report` log line. Carmin reviews the counts.
3. With Carmin's go-ahead, run it again with `dry_run: false`.

## Not covered / open

- **Non-stock / "demand" items** are Sysco's own stock (LOCAL_SALES) but block the whole order's online Cancel on sysco.com: `allItemsAreStocked` must be true. They stay on EnPlace; labelling them "special order, can't cancel after submit" is open.
- **Recording split orders:** our Order row stores one total and confirmation. Sysco's real order number (`orderNumber`, e.g. `2770289`) is available from the order headers. This is open.
- Order #337 is placed. Its Marketplace orders M8490e288fadc (Dot Foods) and M9dac2eb0f65e (Melting Forest) have to be cancelled through the Sysco rep.
