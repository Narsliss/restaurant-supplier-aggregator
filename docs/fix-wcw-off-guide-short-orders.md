# What Chefs Want: never ship a short order (off-guide items)

**Date:** 2026-10-03 · **Status:** built, full suite green (1,726 examples), live-tested, not yet deployed · **Order placement:** TOUCHED. WCW gets a cart check before submit (fails closed), and the confirmation number must come from WCW.

## What happened

Order #388 (Oct 1, Noche, Skyllar):

| | Items | Total |
|---|---|---|
| EnPlace showed | 3 (chicken, blackberries ×2, pear purée ×3) | $170.35, all "added" |
| WCW's own record (`ordersByCustomer`) | 1 | $107.90, the chicken only |

The blackberries (10407) and pear purée (95839) weren't in Noche's WCW order guide.

## Why

- **The draft needs a multi-unit product id.** WCW's draft mutation takes a `multiUnitProduct` id, which we only get from the chef's order guide (`build_order_guide_mup_map`; see commit `cea1340`).
- **The off-guide fallback returns the wrong kind of id.** `resolve_product_id_via_search` returns a **canonicalProduct** id; the code comment already said "may not work for drafts".
- **Nothing noticed.** The item was still counted as added. `checkout` only checked `itemCount > 0` and then submitted whatever the draft held.

**Live test** (Oct 3, Noche's WCW login, approved by Carmin): we built a draft the normal way with chicken (on the guide) and blackberries (off-guide), read it, then emptied it. Nothing was submitted.
- WCW reported **`itemCount: 2`** but returned **one** line: chicken, `itemCode "18271"` (its multi-unit product also `18271`).
- The blackberries were **not in the draft**.

The off-guide id is accepted and then silently ignored, and `itemCount` still counts it.

## Fix

- **`WhatChefsWantScraper#verify_cart_matches!`** re-reads the draft and compares it with the order line by line. Before this, WCW had no such check. The placement service already calls it before checkout, dry runs included.
  - A line answers to its own `itemCode`, its multi-unit product's code, and each variant's code. A guide SKU can be a variant.
  - **Missing line:** `ItemUnavailableError` naming the item. The order stops (all lines kept), with the reason "What Chefs Want didn't add it to the cart (it isn't in your What Chefs Want order guide)" when it went through the search fallback.
  - **Wrong quantity or extra line:** `CartMismatchError`, so the order goes to review.
  - **Draft can't be read back:** `ScrapingError`; nothing is submitted.
  - **Clean-up:** after a failed check, the draft is emptied, so no half-built draft is left at WCW.
- **No made-up confirmation.** `checkout` used `order['id'] || "WCW-<timestamp>"`. A missing id is now `OrderUnconfirmedError`, which parks the order in `pending_manual` (not retryable).

## Verified

- `spec/services/scrapers/what_chefs_want_cart_check_spec.rb`:
  - the #388 case stops the order and names both items
  - a full match passes
  - the variant-code match passes
  - a quantity difference and an extra line each stop for review
  - an unreadable draft fails closed
  - a real WCW id is used, and a missing one raises
- The live draft above confirmed the real line codes match our catalog SKUs (so guide items pass), and that off-guide items are absent (so they're caught).

## Part 2: actually ordering off-guide items (same day)

**How WCW's own site does it.** Captured in the browser pane on Carmin's login: one Blackberries added from Catalog search, then removed. The cart ended back at $0.00 and existing drafts were untouched.
1. `CreateHiddenShopProductMutation(canonicalProductId: 342231776, formId, locationId, sourcePage: "Catalog", sourceLocation: "Catalog Search", isOperatorAdded: true, isSupplierAdding: false)` returns a **MultiUnitProduct** attached to the restaurant's order form as a *hidden* product (it doesn't show on the visible guide).
2. `CreateOrUpdateDraftMutation` with that MultiUnitProduct id.

We had been skipping step 1 and sending the canonical id straight to the draft.

**Fix:**
- **`WhatChefsWantApi#create_hidden_shop_product`:** a minimal version of the same mutation.
- **`WhatChefsWantScraper#add_off_guide_product`:** off-guide SKU → canonical id (**exact** item-code match only; the old "single fuzzy result" fallback could order a different product) → hidden shop product → its id goes in the draft.
- **If WCW won't attach it:** the item is reported failed ("What Chefs Want couldn't add it from its catalog"), so the order stops.
- **`verify_cart_matches!` (part 1)** still confirms every line landed before submit.

**Live test** (Oct 3, Noche's WCW login, approved by Carmin; nothing submitted):

| Step | Result |
|---|---|
| Exact search | `10407` → canonical `342231776` |
| Hidden shop product | → `1137706310` (itemCode `10407`, unit Each) |
| Draft with chicken (guide `647035869`) + that id | **both** lines present: codes `18271` and `10407` |
| Cleanup | draft emptied |

## Not done / open
- `get_all_drafts` is broken: WCW removed `allCompanyDrafts`. It's not used in the ordering path.
- How many past WCW orders were short is unknown. The full history comparison timed out; #388 is the confirmed case.
