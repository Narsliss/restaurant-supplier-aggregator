# Fix: Sysco refused every cart line (first live Sysco order, #336)

**Date:** 2026-09-27 · **Status:** built, full suite green (1,563 examples), not yet deployed · **Order placement:** TOUCHED — Sysco `add_to_cart` line shape

## What happened

The first live Sysco order (#336: Alfio's, CJ Moutinho's cred 58, 3 items × 5 CS, delivery Oct 7) failed in 2 seconds:
`Failed to add items to Sysco cart: updateOrderV2 returned nil`. Sysco created the empty draft, rejected the add-items call, and we deleted the draft. **Nothing was submitted; nothing reached Sysco as an order.**

The logs gave no reason. Sysco answers a rejected `updateOrderV2` with HTTP 200, `data: null` and an `errors` array. `graphql_request` only logs bodies on non-200, and `graphql_update_order` read only `data`, so Sysco's reason was discarded.

## What the probes found (live, draft-only, Sep 27)

Three probes on prod through cred 58. Each created a draft, tried `updateOrderV2`, and deleted the draft. None called submit.

1. Every line was rejected with **`order.lineItems[0].price is required`**, for all three SKUs. So the problem was not the Boardwalk item or its seller ID, as first guessed.
2. With `price` added, every line was rejected with **`order.lineItems[0].commissionBasis is required`**.
3. With `price` + `commissionBasis: 0` added, **every line was accepted**. Sysco ignores the price we send: sending `0` stored `40.59` (sugar 4279592) and `33.95` (paprika 1555749), the same as sending the live price. Pricing type came back `N`, totals were computed server-side, and `soldAs` was stored as `CASE`.

Sysco validates one missing field at a time, so it reports only the first gap.

## Why the old code was wrong

Commit 0d4469a (Apr 8 2026) stopped sending `pricingType`, `price`, `totalPrice` and `commissionBasis`. At the time Sysco overrode them anyway, and a hardcoded `pricingType: "N"` made submit reject contract items. Sysco has since made `price` and `commissionBasis` required on update. The April reasoning about `pricingType` still holds, so we still don't send it or `totalPrice`.

## The fix

- **`SyscoScraper#add_to_cart`**: each line now also sends `price: expected_price.to_f` (0.0 when unknown) and `commissionBasis: 0`. Sysco's server still decides the real price.
- **`SyscoScraper#graphql_update_order`**: when rejected, it logs Sysco's full `errors` and raises `updateOrderV2 failed: <Sysco's message>` instead of "returned nil".
- **`PreOrderValidationService`**: the order-minimum and delivery pre-checks now skip when the scraper returns `nil` (Sysco and the `BaseScraper` default). Before, each Sysco order logged two misleading `undefined method '[]' for nil` "check failed" warnings. Behaviour is unchanged, since the old rescue already let the order through.
- Specs: the line shape (price + commissionBasis, no pricingType/totalPrice), the surfaced error message, and the nil pre-check skip. Each fails without its fix.

## What did NOT work / was ruled out

- The login and tokens were fine: seller `USBL`, site `019`, account `usbl-019-707689`, and the JWT was valid at submit.
- It wasn't the case minimum: 15 cases were ordered against a minimum of 15.
- The seller-ID theory for the Boardwalk item was wrong, since every SKU failed the same way.

## Open items

- **Submit is still unverified live.** `graphql_submit_order` sends lines without `price` or `commissionBasis`; its April comments say submit rejects `commissionBasis`. If Sysco has tightened submit too, the next order fails at submit, and a rejected submit places nothing. That can't be probed without placing a real order.
- **Boardwalk 6070898** (on #336): Sysco's price API returns no case price and search returns nothing, so it's likely discontinued or unavailable for this account. Leave it off the next test order. We don't yet handle this case before submit.
- **Every Sysco line is ordered as a case** (`soldAs: 'cs'`), whatever the order item's `uom` says. An "each" line on a split item would arrive as cases. Not addressed here.
- The confirmation number after submit may be our own timestamp name, not Sysco's; check it against Sysco's portal after the first real order.
