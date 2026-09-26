# Owner multi-location ordering: findings

**Started:** 2026-09-26 · **Status:** investigation; nothing built yet

## The need

Alfio (owner, org 7, user 10) runs alfios, Noche and D'oro. D'oro opened recently, and he will be ordering across all three.
- **Picker suppliers:** at every supplier except Performance, he has **one login with a restaurant picker**.
- **Performance:** he has three separate logins, one per restaurant. That already fits EnPlace's model of one connection per location.
- **Chefs:** each chef uses their **own** login. That is intentional, because it is how savings get attributed to whoever ordered. Borrowing or sharing chef logins is ruled out.

**The agreed design** (Carmin, Sep 26):
- For picker suppliers, Alfio connects once and matches the supplier's restaurants to his EnPlace locations, one time.
- Syncs switch to each location's restaurant before pulling its guides.
- Ordering switches to the order's restaurant, reads the ship-to back, and **refuses to submit on a mismatch**. This is an ordering change, and it needs tests and explicit sign-off.
- Orders stay under his own login.

**Why it is safe today:**
- Alfio's connections all belong to alfios, and EnPlace only offers an owner the connections for the current location. He cannot misroute from Noche or D'oro.
- All of his 29 historical EnPlace orders are alfios orders.

**Required regardless of supplier:** `OrderPlacementService#get_active_credential` picks the ordering user's connection by supplier only, not by location. It must become location-aware before anyone holds two connections for one supplier.

## Built: "You are ordering for" banner (Sep 26 2026, display only)

Carmin: chefs are often in a hurry, so the order builder and the cart must say unmissably which restaurant an order is for.

- `shared/_ordering_for_banner` appears on the desktop and mobile order builder and the desktop and mobile review/cart. On the mobile builder it sits inside the sticky header, so it stays on screen while scrolling.
- **Only for people who can switch restaurants in EnPlace**: `OrdersHelper#ordering_for_banner` renders it only when the user is not a chef and has more than one accessible location, the same people who get the nav's location dropdown. Carmin's rule: a chef who can only ever order for one restaurant keeps the screen space.
- **Normal state:** bold orange (`bg-brand-orange-dark`, white text, ring) showing "YOU ARE ORDERING FOR", the restaurant name and its address. Charcoal "brand-navy" was tried first and was nearly invisible in dark mode.
- **Red, mismatch:** the location the orders will be recorded against (`current_location`, which `OrdersController#create_from_aggregated_list` uses) differs from the location of the list being viewed.
- **Red, missing:** no location. The builder already refuses to render without one (`require_location_context!`); the missing state is a safety net.
- **The review page** shows the location the orders actually carry (`@orders.first.location`).
- `bin/rails tailwindcss:build` was run for the new classes. The compiled CSS is committed.
- Tests: `spec/requests/ordering_for_banner_spec.rb` (7 examples).
- It does not change how orders are placed.

## US Foods: recorded Sep 26 2026

Carmin signed in as Alfio in the in-app browser and switched alfios → Noche → D'oro → alfios while the app's state was observed. The observation read only account fields; no token or password was read out.

| Restaurant | Picker label | customerNumber | divisionNumber |
|---|---|---|---|
| alfios | Alfio's Buon Cibo Pnto | 80998842 | 1103 |
| Noche | (Noche) | 31718356 | 1103 |
| D'oro | D Ore Restaurant Pnto | 11806627 | 1103 |

- **How the picker works:** switching stores `auth-context` (`{divisionNumber, customerNumber, departmentNumber}`) and re-issues the API access token. The token's `usf-claims` carries `customerNumber`. We confirmed a fresh token at 15:23, 15:24 and 15:25 UTC, each with the chosen customer.
- **In EnPlace terms:**
  - *Switching:* `UsFoodsApi#refresh_access_token` already sends `authContext` from `@auth_context`. Switching means refreshing with the target restaurant's customer number.
  - *Verifying:* decode `usf-claims.customerNumber` from the access token that is about to be used, and compare it with the order's location.
- The customer numbers match the chefs' own per-location connections, which were verified on Sep 25 from their saved sessions.
- The browser pane did not capture the cross-origin calls to `panamax-api.ama.usfoods.com`, so we have not seen the exact request the site makes for the switch. The token and auth-context evidence is conclusive about the outcome.
- **Listing a login's restaurants:** `GET /customer-domain-api/v1/customers` returns an array.
  - Each entry has `customerNumber`, `divisionNumber`, `customerName`, `city` and address fields.
  - Alfio's login (cred 75) returns 3: ALFIO'S BUON CIBO PNTO 80998842 (Cincinnati), NOCHE PNTO 31718356 (Covington) and D ORE RESTAURANT PNTO 11806627 (Blue Ash).
  - A chef's login (Nate, cred 90) returns 1. Connect-time detection is therefore simple: more than one customer means the one-time matching step is shown.
  - Found in the site bundle as `${customerApiUrl}/customers`. `/user-domain-api/v1/identity` does not include customers.
- **Server-side switch, proven Sep 26** (`tmp/usf_switch/usf_switch_test.rb`, authorized by Carmin): cred 75 was switched to Noche and back through `refresh_access_token` with a changed `@auth_context`.

  | Step | Saved context | Token `usf-claims` | `list-domain-api/v1/orderGuides` |
  |---|---|---|---|
  | start | 80998842 | 80998842 | guide `…38cf`, customer 80998842 |
  | switched | 31718356 | 31718356 | guide `…f295`, customer 31718356 (Noche's data) |
  | restored | 80998842 | 80998842 | guide `…38cf` |

  **Caution:** a refresh persists the new context to the credential through `save_session_tokens`. Any switch must restore (or target) deliberately, because the credential's saved context is what every later sync and order uses.
- An earlier attempt crashed on an invalid first line (`require "json", "base64"`) before touching anything. The START line of the next run confirmed that the connection was unchanged.

## Other suppliers (from Alfio's saved sessions, read-only, Sep 25)

- **Chef's Warehouse:** `/web-api/organization/list` returns ALFIO'S (614969), D'ORO (9528299) and NOCHE (9508766). `current-user` shows `currentOrganizationId` 614969, with shipTo 614969 at 2724 Erie Ave. His connection also imports D'oro's guides into alfios. The switch has not been recorded yet.
- **What Chefs Want:** his login reported only **one** location (CINCINNATI). This needs checking with him.
- **PPO:** his connection has been expired since Aug 18. Only Alfio can reconnect it, because the login code goes to him.
