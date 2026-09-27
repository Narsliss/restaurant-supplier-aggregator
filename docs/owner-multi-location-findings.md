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

## Built on branch `multi-location-switching` (Sep 26 2026; not merged or deployed)

Carmin: "build all that we have tested … keep the blast radius confined to owners and managers." This covers US Foods, Chef's Warehouse, What Chefs Want and (added Sep 27) Premiere ProduceOne.

**Blast radius.** Nothing changes for a connection unless it has **restaurant matches**. Matches can only exist on an owner's or manager's connection: the model validation checks the connection user's role in the organization, and the matching page is limited to owners and managers. Every chef, and every single-restaurant login, runs the exact old code path; tests assert that directly.

**Pieces:**
- `supplier_credential_restaurants` table and model: a connection plus an EnPlace location mapped to a supplier account id (USF customer number with its division in `account_meta`, CW organization id, WCW company id). Each location and each account id may appear only once per connection. The table also adds `supplier_credentials.supplier_restaurant_count`.
- **API calls:**
  - `UsFoodsApi#list_restaurants`, `#switch_customer!` and `#token_customer_number`
  - `ChefsWarehouseApi#list_restaurants`, `#set_organization!` and `#current_ship_to`
  - `WhatChefsWantApi#list_restaurants` (current company plus `additionalCompanies`), `#switch_company!` (then `discover_context`) and `#current_company_id`
  - `PremiereProduceOneApi#list_restaurants`, `#select_restaurant!` and `#current_restaurant_uuid` (Sep 27)
  - The USF, CW and WCW methods are additive. PPO changes one existing method: `extract_context` used to take the login's **first** restaurant; it now takes the restaurant saved with the session (else the first), and a pinned one while switched. For a single-restaurant login the result is the same restaurant as before.
- **`Suppliers::RestaurantSwitcher`**: switch to the location's restaurant, confirm the supplier reports it, run the work, then switch back home.
  - A mismatch raises `MismatchError` **before** the work runs.
  - A failure to switch home is logged and never masks the work's own error.
  - A Postgres advisory lock per connection keeps a sync from switching the login in the middle of an order.
  - It is a no-op without matches. `enter`/`leave` form a non-block version for `begin/ensure` flows.
- **`Suppliers::OrderCredential.scope(order)`**: the old query unless the user has matches for that supplier; then only connections that serve the order's location (`SupplierCredential.serving_location`).
- **Ordering** (needs Carmin's sign-off before merge):
  - `OrderPlacementService` switches and confirms before `clear_cart`, and switches home in `ensure`. Its credential lookup is now location-aware; with no matches it is the same `find_by` as before, as `.take`.
  - Location-aware lookup plus a switch around the supplier call in `PriceVerificationService`, `SupplierExceptionChecker` (USF only shows an order to the restaurant it was placed for) and `VerifyItemPriceJob`.
  - `OrderValidationService#validate_account_status` gets the location-aware lookup.
- **Syncs.** `ImportSupplierListsService` syncs each matched restaurant into its own location. For the other restaurants it:
  - never takes over a list another connection owns;
  - leaves a new list ownerless rather than clash on a repeated remote id (WCW `order-guide`, CW `-1`);
  - judges "list gone" only within the synced restaurant;
  - skips order-list seeding.

  A restaurant that fails to switch is skipped and reported; the others still sync. Side effect: `SyncAllListsJob` already prefers the owner's connection, so once matched, the daily sync keeps Noche's and D'oro's guides fresh too. Today they only refresh when a chef refreshes them.
- **The no-supplier fallback is location-aware** (Sep 27; Carmin: "what if he selects D'oro and adds items from a supplier he has no D'oro restaurant for?"):
  - `Orders::AggregatedListOrderService.orderable_supplier_ids(user, location:)` only counts connections that serve the order's restaurant. The order service passes its location, and the builder passes `current_location`.
  - This closes a path that exists on `main` today. A legacy flat-param line with no supplier, for one restaurant, could fall back onto an owner's login for another restaurant and ship there.
  - Sep 27 hardening: the filter applies only to a user whose active logins span more than one restaurant (or have restaurant matches). A single-restaurant chef keeps the plain list whatever location their connection records, so this no longer depends on production data being tidy.
  - With no location given, behaviour is unchanged.
  - Regression test: "never falls back onto the user's login for a different restaurant".
- **Scoped credentials.** For owners and managers only, a location's connections include those matched to it, so the builder and cart at Noche offer Alfio's matched logins. The chef branch is untouched.
- **Matching step:**
  - `ValidateCredentialsJob` records the restaurant count for owner/manager logins (best effort; chefs skipped).
  - `supplier_credentials/:id/restaurants` shows the live list with a location picker. The home location is required, a location can be used only once, a save replaces all matches and starts a sync, and there is a "Stop using this login for other restaurants" action.
  - The suppliers page shows the link only to owners and managers with more than one restaurant, on those four suppliers.
- **Tests:** 60 new examples in `spec/services/suppliers/restaurant_switcher_spec.rb`, `spec/services/orders/multi_restaurant_ordering_spec.rb`, `spec/services/import_supplier_lists_multi_restaurant_spec.rb`, `spec/requests/supplier_restaurant_matching_spec.rb` and `spec/services/scrapers/restaurant_picker_api_spec.rb`, with `FakeRestaurantApi` in spec/support. The full suite of 1,436 examples passes.

**Not verified end to end:** switching was proven on production with scripts, but this code has not run against a real supplier. Dev has no live supplier sessions. The first real run should be a sync of Alfio's matched logins, watched, before any order.

**Open items:**
- **PPO:** investigated and built Sep 27 (below). A server-side run still needs Alfio's EnPlace PPO connection (cred 73, expired since Aug 18) reconnected; the code goes to Alfio.
- **Mobile suppliers page:** has no "Restaurants" link yet; matching is desktop only.
- **Residual race:** `RefreshSessionJob` and catalog imports use the connection without taking the switch lock. With USF, a token refresh that overlaps a switched window could save the other restaurant's context. Every sync and order switches deliberately anyway, so ordering cannot be misrouted; at worst a catalog import could read the other restaurant's prices. The mitigation is to run those jobs through `with_restaurant(credential.location_id)`.

## Performance: a separate login per restaurant (Sep 27 2026)

Performance has no picker: each restaurant has its own login (email). An owner who orders for all of them holds several Performance connections under one EnPlace account, one per restaurant. Carmin's model: "when they create the supplier credentials it explicitly asks which location this supplier connection is for … smart enough to not select the same location multiple times."

**The problem found (on `main` today).** The screens already respected each connection's restaurant, but the step that sends an order picked "the user's active login for this supplier" with no restaurant check. With three Performance logins, a D'oro order could go out through the alfios login and ship to alfios.

**Built (Carmin: "build both"):**
- **Orders follow the restaurant.** `SupplierCredential.spans_restaurants?(creds)`: a user's logins for a supplier cover more than one restaurant (attached to different locations, or restaurant matches). Then `Suppliers::OrderCredential` accepts only a login serving the order's restaurant; with none, the order is marked failed and raises "No active credentials". Anyone with one login per supplier (every one-location chef) gets the exact old query. The same rule drives the builder fallback. Sysco is covered too if it ever has several logins.
- **Connect form asks.** Owners with 2+ restaurants get "Which restaurant is this login for?" (defaults to the one selected at the top). Restaurants that already have the chosen supplier are greyed out ("already connected"), and the supplier stays offered until every restaurant has it. The server re-checks: the location must be one of the owner's own restaurants, and the existing duplicate check (user + supplier + location) still applies.
- **Two holes closed while there:**
  - `create` used to accept any posted `location_id` without checking it belongs to the user. Now owners with a choice must pick one of their accessible restaurants; everyone else always connects for their current restaurant.
  - The edit form re-posted the location selected at the top of the screen, and `update` saved it. On `main` that was harmless (owners only see logins at the current location), but on this branch a matched alfios login viewed from Noche would have moved to Noche. Edits now never change a connection's restaurant, and the edit form just shows it.
- **Tests:** `spec/requests/supplier_credential_location_choice_spec.rb` (9) and three Performance cases in `spec/services/orders/multi_restaurant_ordering_spec.rb` ("sends a D'oro order through the D'oro login", "fails … rather than use the alfios login when D'oro's login is not active", "fails loudly for a restaurant with no login of its own"). The form's greying-out script was checked in the dev browser. Full suite: 1,448 examples, 0 failures.

**Still to decide (interview in progress):**
- ~~Pre-order check~~ **Built Sep 27 (Carmin: "yes, make that change").** `PreOrderValidationService` (run by `PlaceOrderJob` before every real order; missed in the first branch audit) used `user.credential_for(supplier)`: any login, any status. It now takes `location_id:` from the order and uses `Suppliers::OrderCredential.for(...)`, the same rule as sending. Unchanged for one-login users. For the four picker suppliers it only refreshes the login and uses cached data. Tests: 3 in `pre_order_validation_service_spec.rb` plus a wiring test in `multi_restaurant_ordering_spec.rb`. That spec's header claimed pre-order validation was dead code; that is stale, and the header is corrected. Full suite: 1,452 examples, 0 failures.
- ~~Account hold~~ **Built Sep 27 (Carmin: "yes, make that change").** `handle_account_hold_error` used to mark "any" login for the supplier as on hold; it now marks the login that placed the order. Test: "puts only the D'oro login on hold …". Full suite: 1,453 examples, 0 failures. Note: a picker supplier's one login serves every matched restaurant, so a hold reported for one restaurant still puts that shared login on hold.
- ~~Minimum suggestions~~ **Built Sep 27 (Carmin: "yes, make that change").** `MinimumSuggestionService#from_order_guides` used to suggest from any login's guide; it now uses the guide of the order restaurant's login (`OrderCredential.for`). New `spec/services/orders/minimum_suggestion_service_spec.rb` (2), confirmed to fail on the old lookup. Tier 1 ("recently ordered") now counts only orders for the same restaurant, plus orders with no recorded restaurant, so one-location users are unchanged (Carmin: "if the change is easy, make it"). Test: "suggests what was recently ordered for D'oro, not for alfios".
- List syncing picks one login per supplier per organization (`SyncAllListsJob`). **Tabled by Carmin:** matched lists matter more than guides, and the catalog more than both.

## Owner onboarding redesign: automatic restaurant linking (decided and built Sep 27 2026, uncommitted)

Carmin: "asking them to match locations to logins (aside from performance) seems insane to me, can't we do something smart with addresses". Scenarios walked through: a new owner starting with 3 locations, and an existing client adding a location.

**Decisions (interview, Sep 27):**
- **Auto-link by address.** A supplier restaurant is linked to the EnPlace restaurant with the same **street number + 5-digit zip**, only when exactly one matches (one-to-one). Never by city: US Foods calls D'oro "Blue Ash", PPO calls it "Montgomery", and both say 45242. EnPlace restaurants always have address, city, state and zip (required by `Location` validations).
- **Chef's Warehouse** has no addresses in its restaurant list (see below). Link on an **exact name match** (ignoring case and punctuation), or on the **account number from a chef's own login** at that restaurant (also usable for every supplier). Carmin: "that's good enough for CW".
- **Anything uncertain** stays unlinked, with a one-click "Which of these is Noche?" fix shown **in the order builder at that restaurant and on the Suppliers card**. A supplier that simply doesn't list a restaurant gets a quiet line ("What Chefs Want doesn't list D'oro on this login"), not a prompt.
- **Re-check** when a location is added, and daily (suppliers often set up a new account days or weeks later).
- **Silent success.** Carmin: "quietly start working, chefs hate clutter; only alert a chef when something is going wrong."
- **Who:** owners and managers only, and only when the organization has 2+ restaurants and the login lists 2+. Chefs are untouched.
- **One connection per supplier per owner** for picker suppliers (US Foods, CW, WCW, PPO). The old blocker is per restaurant only ("same user can connect the same supplier at different locations"), and switching the top location let an owner connect the same picker login twice: two connections fighting over one supplier account.
- **Suppliers page for owners ignores the location switcher:** one card per supplier. Picker cards list the restaurants they cover. **Performance (and Sysco until investigated) is one card holding a login per restaurant**, with "Add login for another restaurant" using the restaurant dropdown.

**Supplier address data (read-only production probe, Sep 27, one chef login each, nothing switched or saved):**

| Supplier | Address in restaurant list? | Evidence |
|---|---|---|
| US Foods | Yes | `/customer-domain-api/v1/customers` address fields (Sep 26) |
| PPO | Yes | `employee_chats.restaurant_address` (Sep 27) |
| What Chefs Want | Yes | GraphQL `Location { address city zip }`; Nate's Noche: "701 MADISON AVE", COVINGTON, 41011 |
| Chef's Warehouse | **No** | `/web-api/organization/list` keys are only `id,isActive,name,primaryBU,sourceName`. Only the *currently selected* organization carries `shippingAddress1/City/State/Zip` (Michael's D'oro: 1100 SUMMIT PL, BLUE ASH OH 45242), and that address came back blank right after a switch on Sep 26. |

**Built (Carmin approved the mockup: "yeah I think that's fine"):**
- **Data.** Migration `20260927150000`: `supplier_credentials.supplier_restaurants` (jsonb snapshot of the login's restaurants: id, name, street, city, zip, meta) and `supplier_restaurants_checked_at`. Each picker API's `list_restaurants` now returns `street/city/zip`:
  - US Foods: parsed tolerantly (`address1`, `addressLine1`, …, `zip`, `zipCode`, …), because the exact customer field names are **not yet confirmed**. The preview run should confirm them.
  - WCW: `locations { id address city zip }`, with location ids in `meta` for the chef cross-reference.
  - PPO: `restaurant_address` parsed by `Suppliers::RestaurantAddress.parse`.
  - CW: none.
- **`Suppliers::RestaurantAddress`:** street number, zip5 (handles `45208-1234` and `452081234`, a bug the specs caught), one-line parsing, and normalized names.
- **`Suppliers::RestaurantAutoLinker`:**
  - Links only certain, one-to-one matches: address (street number + zip5), the account saved on a chef's own single-restaurant login (USF `auth_context.customer_number`, PPO `api_tokens.restaurant_uuid`, WCW `api_context.location_id`), or, for CW only, an exact normalized name.
  - Never changes existing links, and links nothing unless the login's home restaurant is linked.
  - Supports `dry_run:`; `run_safely` never raises.
  - CW has no chef cross-reference: CW doesn't save the restaurant a login is on, and reading chefs' CW logins live was left out to keep chefs untouched.
- **Safety rails:**
  - `SupplierCredentialRestaurant` refuses a non-home link before the home one is linked.
  - `RestaurantMatching#save` creates the home link first.
  - `RestaurantSwitcher#enter` now **raises** for a linked login asked to work for a restaurant it isn't linked to (it used to pass through silently).
  - `list_restaurants` holds the per-connection switch lock.
- **Triggers:**
  - on validation (`RestaurantMatching.record_count` now runs the linker);
  - on a new location (`Location after_create_commit`, organizations with 2+ restaurants);
  - daily at 10:30 UTC (`AutoLinkSupplierRestaurantsJob`, `config/recurring.yml`).
  - All only for owner/manager logins on picker suppliers in 2+ restaurant organizations.
- **Owner Suppliers page (`@owner_view` = owner with 2+ accessible restaurants):**
  - The page (and `set_credential`) uses all of the owner's connections org-wide, whatever location is selected.
  - The card was moved unchanged into `_credential_card.html.erb`.
  - `_restaurant_links.html.erb` shows "Orders for" chips, an amber one-click fix per unplaced restaurant (`PATCH link_restaurant`), and a quiet "doesn't list X on this login" line.
  - Performance and Sysco (non-picker) render as one card per supplier with a slot per restaurant; empty slots link to the connect form with that restaurant preselected.
  - Mobile shows the same chips and fixes, plus "For <restaurant>" on per-restaurant logins.
  - Managers and chefs are unchanged.
- **One connection per picker supplier (owners with 2+ restaurants).** The connect form stops offering US Foods/CW/WCW/PPO once connected, and `create` refuses a second one ("already connected … linked automatically").
- **Order builder:** `OrdersHelper#supplier_setup_notice` shows "US Foods isn't set up for Noche yet … Fix it" (desktop and mobile) only when a picker login lists an unplaced restaurant and nothing serves this restaurant from that supplier. Silent otherwise; never for chefs.
- **Tests:**
  - `restaurant_auto_linker_spec` (15), `auto_link_supplier_restaurants_job_spec` (4), `owner_suppliers_page_spec` (9) and `supplier_setup_notice_spec` (5);
  - updated picker, switcher and matching specs;
  - two seed-dependent specs made self-contained (`supplier_list_item_spec`'s Sysco and `supplier_restaurant_matching_spec`'s scraper), because they blocked the pre-Bash test hook after every test-DB migration.
  - Full suite: 1,490 examples, 0 failures.
  - Chef view confirmed in the dev browser (a chef account: same six cards, no chips, no grouped card). The owner view is covered by request specs only.

**Preview on Alfio's real data (Sep 27, auto mode off, Carmin's OK).**

A read-only production pull (restaurant lists, org 7 addresses, and chefs' saved accounts; no switching, no carts) was fed through the real `list_restaurants` parsing and `RestaurantAutoLinker` in the **test DB inside a rolled-back transaction**. Nothing persisted.

- **US Foods customer fields confirmed:** `address1`, `city`, and `zip` as a 9-digit **integer** (452080000); `zip5` handles it.
- **Finding: Alfio already holds duplicate picker connections** from connecting per restaurant: US Foods #75 (alfios) and #132 (D'oro), CW #72 (alfios) and #135 (D'oro), PPO #73 (alfios, expired) and #136 (D'oro).
  - New rule (`Suppliers::RestaurantLinks`): a restaurant or account covered by the owner's *other* connection for the same supplier counts as placed. It is never linked twice, never offered in the fix, and never reported as unlisted.
  - A fix box only shows while a restaurant is free to pick.
- **Result (final state, daily-job order):**

  | Restaurant | US Foods | Chef's Warehouse | What Chefs Want | PPO |
  |---|---|---|---|---|
  | alfios | #75 (home) | #72 (home, name) | #78 (home, address) | #136 by address (in prod #73 is attached here, so #136 won't take alfios; alfios PPO waits for #73's reconnect) |
  | Noche | #75 (address) | #72 (name) | **one-click fix**: WCW gives no address for additional companies | #136 (Nate's saved restaurant) |
  | D'oro | #132 (home) | #135 (home) | not served, quiet line once Noche is fixed | #136 (home) |

  Every other link is automatic.

## Audit: single-location chefs (Sep 27 2026, before commit)

Carmin: "this will in no way negatively impact chefs with only one location." Every changed path, checked against a chef with one restaurant and no restaurant matches (matches can't exist on a chef's login):

| Path | For that chef |
|---|---|
| Which login places / verifies / checks an order (`OrderCredential`) | The exact old query (`find_by` → `.take`) |
| Order placement, price verification, USF exception check, item verify | Switcher returns at once; no supplier call, no lock, API client never built (made lazy Sep 27) |
| Builder default / no-supplier fallback | Unchanged (location filter only for users whose logins span restaurants — Sep 27) |
| Suppliers page / scoped credentials | Chef branch untouched; owner/manager branches identical without matches |
| List sync | Same location, same syncing login, seeding still runs, stale-marking unchanged |
| Connecting a supplier | No restaurant-list call for chefs, nor (Sep 27) for owners with one restaurant |
| PPO | One-restaurant login resolves the same restaurant; a multi-restaurant login now keeps its saved restaurant instead of whichever Pepper lists first |
| Matching page and link | Owners/managers with 2+ restaurants only |

Pinned by `spec/services/single_location_chef_unchanged_spec.rb` (8 examples).

**Every order/sync step for the four suppliers runs on the switched API client.** Checked in the scrapers: USF, CW, WCW and PPO `scrape_lists`, `scrape_prices`, `add_to_cart`, `clear_cart`, `checkout` (and USF `fetch_submitted_order`) call only `api_client`; the browser is used for login only. So nothing in an order can bypass the switch.

**Not checked:** a production read confirming every chef's connection is recorded on their own restaurant was blocked by auto mode. The Sep 27 fallback hardening makes the answer irrelevant for single-restaurant chefs.

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

## Chef's Warehouse: proven Sep 26 2026

No browser sign-in was needed. CW is email and password, so EnPlace already holds a live session for Alfio (cred 72).

- **List:** `POST /web-api/organization/list` returns `[{id, name, isActive}]`, where `isActive` marks the currently selected restaurant. Alfio has ALFIO'S 614969, NOCHE 9508766 and D'ORO 9528299.
- **Switch:** `POST /web-api/organization/set?value=<org id>`, with an empty body and a `null` response. Found in the site bundle `main.*.js` as `setActiveOrganization`.
- **Verify:** `POST /web-api/auth/current-user` → `currentOrganizationId` and `currentOrganization.shipTo`. Compare **shipTo**, not the address; `shippingAddress1` came back blank after a switch.
- **Test** (`tmp/cw_switch/cw_switch_test.rb`, authorized by Carmin; cart never touched):

  | Step | currentOrganizationId / shipTo | Order guides (`/web-api/order-guide/header-list`) |
  |---|---|---|
  | start | 614969 ALFIO'S | Alfio Full Order Guide, ITALIAN PROMO |
  | → NOCHE | 9508766 | noche, Hedley & Bennet Aprons (the same guides as Nate's own login) |
  | → D'ORO | 9528299 | D'oro Full Order Guide, ULTIMATE BAR GUIDE (the same guides as Michael's) |
  | restored | 614969 ALFIO'S | Alfio Full Order Guide, ITALIAN PROMO |

- **This explains D'oro's guides in alfios:** CW returns guides for the **currently selected** restaurant only. Alfio's selection must have been D'oro when the Sep 17 sync ran, so lists 162 and 163 were filed under alfios. Switching deliberately before every sync prevents it.
- The switch persists at CW. Like US Foods, every sync and order must switch deliberately to its restaurant first.

## What Chefs Want (Cut+Dry): proven Sep 26 2026

- On Cut+Dry each restaurant is a separate **company**. The picker is "Company: Alfio's Buon Cibo (5ALFIO)" (Carmin signed in in the browser pane; the switch was located in the site's loaded webpack modules).
- **List:** GraphQL `user { company { id name } additionalCompanies { id name } }`. **Not** `user.companies`, which returns only the current company; that is why the first read showed one restaurant. GraphQL introspection is disabled, but the server's "Did you mean …?" hints work on near-miss field names.
  - Alfio's saved login (cred 78, alfio@las-noches.com) is currently on Alfio's Buon Cibo 342485441 and can switch to Noche Covington 499909181.
  - **D'oro is not a What Chefs Want customer.** No company exists, and no D'oro user has a WCW connection.
- **Switch:** `GET /login/switchCompany/<company id>` with the session cookies. It returns HTTP 307 → `/`. It is not a GraphQL mutation, which is why the in-page recorder missed it.
- **After a switch, re-discover the context.** Vendor, location and form (order guide) IDs differ per company. `WhatChefsWantApi` caches `vendor_id`/`location_id`/`form_id` in `session_data['api_context']` and takes `locations.first`. Both must become per-location.
- **Test** (`tmp/wcw_switch/wcw_switch_test.rb`, authorized by Carmin; no cart touched):

  | Step | company | vendor / location / form |
  |---|---|---|
  | start | 342485441 Alfio's Buon Cibo | 342485450 / 342485440 CINCINNATI / 342485451 |
  | → Noche | 499909181 Noche Covington | 499909190 / 499909180 COVINGTON / 499909191 (identical to Nate's own Noche connection) |
  | restored | 342485441 | 342485450 / 342485440 / 342485451 |

## Premiere ProduceOne (Pepper): proven Sep 27 2026

- Carmin signed in to premierproduceone.pepr.app as Alfio in the browser pane and switched the picker Noche → D'oro.
- **The picker is client-side only.** The site stores the choice in the browser (`localStorage.userSettings.selectedRestaurantUUID`) and passes `restaurantUUID` on **every** catalog/guide/cart/order call. Nothing is switched at Pepper, so there is nothing to switch back and no cross-job leakage at the supplier.
- **List:** the `employee_chats` query our login already runs returns one chat per restaurant. The same query with `restaurant_name restaurant_account_id restaurant_address` gives names:

  | restaurant | account | restaurant_uuid | chat_uuid | status |
  |---|---|---|---|---|
  | ALFIO'S BUON CIBO (Cincinnati) | ALFBUO | a7b88739-85ae-438e-8820-35d530b794bc | 32770908… | ACTIVE |
  | NOCHE (Covington) | NOCHE | eb8856de-90cf-4858-ad89-9e554bf12311 | 8e0ea39a… | ACTIVE |
  | D'ORO RESTAURANT (Montgomery) | DORO | b2171ba1-5fd5-412c-9808-cb515494a3f5 | c47dd5c2… | NEW |

  D'oro's `status` is `NEW` (not yet `ACTIVE`) at PPO.
- **Proof (read-only):** the same token asked for `getOrderGuideItems` with each restaurant UUID and got each restaurant's own guide: alfios 107 items, Noche 129, D'oro 129 (alfios shares 80 SKUs with Noche and 89 with D'oro).
- **Latent issue on `main`:** `extract_context` took `employee_chats.first`, and Pepper gives no ordering guarantee. For a multi-restaurant PPO login, a token refresh could land the connection on a different restaurant. Fixed on the branch: prefer the restaurant saved with the session.
- **Built:**
  - Switch = pin: `select_restaurant!` sets `SupplierCredential#pinned_supplier_account_id` (in memory, never saved) and re-reads the login's restaurant list. Every call then carries that restaurant's UUID and chat.
  - The pin lives on the credential object, so a PPO client rebuilt mid-order (`close_api_client`) restores onto the pinned restaurant, not home.
  - A pinned restaurant the login no longer has leaves the restaurant **blank** (calls fail) instead of falling back home; the switcher's confirm then raises `MismatchError` before any work.
  - `save_session_tokens` always saves the home restaurant, never a pinned one.
  - Tests: 6 in `restaurant_picker_api_spec.rb`, 2 driving the real PPO client through `RestaurantSwitcher` in `restaurant_switcher_spec.rb`. Full suite 1,428 examples, 0 failures.

## Other suppliers (from Alfio's saved sessions, read-only, Sep 25)
- **What Chefs Want:** his login reported only **one** location (CINCINNATI). This needs checking with him.
- **PPO:** his connection has been expired since Aug 18. Only Alfio can reconnect it, because the login code goes to him.

## Check against main's CW hotfix (Sep 27 2026, after commit 27682e9)

Carmin hotfixed production on `main` while this branch was in progress: `5665ebb` (one live CW session per job, never re-restoring stale cookies, because of ARRAffinity), `0f2d8e5` (re-check the CW cart after the price refresh) and `da39f45` (retry after the safety gate).

- **Overlap:** only `chefs_warehouse_api.rb`, and git merges it cleanly. The hotfix *helps* switching: the organization switch and every cart step now run on the same live, server-affine session.
- **Bug found in this branch (not the hotfix):** the CW switch adapter was written as `api.ensure_session! && api.set_organization!(…)`. `ensure_session!` returns `nil` when the session is live (before and after the hotfix), so CW never switched. The confirm step then refused every CW order for a non-home restaurant. That fails safe (no misroute), but CW multi-restaurant would not have worked. Tests missed it because `FakeRestaurantApi#ensure_session!` returns true; the Sep 26 production proof used a script, not this adapter. **Fixed**, with a regression test driving the real `ChefsWarehouseApi` through the switcher, confirmed failing on 27682e9.
- **Combined check:** this branch, the fix and `origin/main` were merged in a throwaway worktree (no real branch touched), and the full suite ran there: 1,505 examples, 0 failures.
