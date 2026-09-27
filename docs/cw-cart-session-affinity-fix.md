# CW orders: keep one session per job (order #331, Sep 27 2026)

## What happened

Leslie (Alfio's, CW cred 94, single-restaurant login) placed order #331: 15 lines, $1,288.72, delivery Mon Sep 28. It failed twice. Nothing was submitted to CW.

Worker logs, Sep 27 UTC:

| Time | Step | Result |
|---|---|---|
| 15:09:45 | `clear_cart` | read the cart, 0 lines, "API cart cleared" |
| 15:10:02 | `cart/add` | success, `totalCount: 16` |
| 15:10:02 | `verify_cart_matches!` | passed |
| 15:10:02 | `checkout` → `get_cart` | `itemCount: 0` → "Cart is empty". The 16 units stayed in the CW cart. |
| 15:11:08 | retry: `clear_cart` | read the cart, **0 lines**, "API cart cleared" |
| 15:11:11 | `cart/add` | `totalCount: 32`. Attempt 1's lines were still there. |
| 15:11:11 | `verify_cart_matches!` | every SKU at 2× → `CartMismatchError` → pending_review |

The July 6 reconciliation gate (commit 8b43b59) stopped a doubled order of about $2,577.

## Cause

Two reads of the CW cart came back empty while the cart held items: checkout in attempt 1, and the clear in attempt 2.

`ChefsWarehouseApi#ensure_session!` runs before every cart step: clear, add, verify and checkout. It used to reload the **saved** cookies from `session_data` each time. Those cookies are only written at login.

A read-only probe of cred 94 (Sep 27, 15:26 UTC) showed that CW replaces `ARRAffinity`, `ARRAffinitySameSite`, `.ASPXANONYMOUS`, `PROD%3AApplicationCookie` and `PROD_cwUserData` on every restore. So the saved affinity pointed at a CW server that no longer exists. Each step of one order started from the stale cookie again and could land on a different CW server. Our reading is that CW's site (Episerver) caches carts per server, so one server's stale copy returned an empty cart.

It worked earlier because, while the saved server still existed, every step went to the same machine.

**Not proven.** The probe could not reproduce the empty read, because all of its reads landed on one server and were consistent. The fix is still correct on its own terms: a job should behave like one browser session.

## Ruled out

- **A restaurant switched mid-order.** Cred 94 has one CW organization (ALFIO'S 614969).
- **Our own jobs touched the cart concurrently.** No other CW job ran in the window.
- **A code change on our side.** Nothing in the CW ordering path changed between July 6 and Sep 27.

## Fix

`ensure_session!` now keeps a live in-job session. If this client already holds cookies, it checks them (`organization/list`) **with the cookies CW last issued**. Only if that check fails does it reload the credential, restore the saved session, and then log in, as before. So the liveness check still runs before every step; it just stops swapping in stale cookies.

`restore_session` shares the same check (`session_alive?`), with no change in behavior.

Specs are in `spec/services/scrapers/chefs_warehouse_api_spec.rb`. They drive the real `request` path against a fake connection and assert that only the first request of a job carries the saved cookie. The key example fails on the old code.

## Not changed / open items

- **Cookies are still saved only at login.** Writing refreshed cookies back to `session_data` would help each new job start on a live server. It was left out on purpose: the multi-location branch switches CW organizations on the same session, and saving cookies mid-switch needs thought there first.
- **A failed checkout still leaves its lines in the CW cart.** The next attempt's verified `clear_cart` plus the gate cover this.
- **Order #331's CW cart still holds 32 units ($2,577.44).** The next placement attempt's `clear_cart` empties it before adding. Nobody should check out that cart on chefswarehouse.com.
- **Merging into the multi-location branch.** `RestaurantSwitcher` calls `set_organization!` on the same client. Keeping cookies within the job suits it, but re-run its specs after the merge.
