# Fix: an unanswered submit never says "safe to try again" (Oct 20 2026)

Status: **committed on branch `claude/elegant-mirzakhani-27fbba` (Oct 20, Carmin approved). Not pushed.** Plan: `docs/plan-ordering-risks-oct20-review.md` (approved by Carmin Oct 20, narrow version).

## What was wrong

When US Foods, Chef's Warehouse or Premiere Produce didn't answer our live submit clearly (a timeout, a dropped connection, an HTTP error, an unreadable page), each made one read straight away. If the order still showed in the cart (or as a draft), we told the chef: "Nothing was placed; it is safe to try again."

That read doesn't prove anything:
- US Foods takes orders asynchronously (order 482 came back SUBMITTING).
- CW and PPO can still be taking an order after our side gave up waiting.

The order went to `failed` with a Fix & Resubmit button. A resubmit clears the submit marker and sends a fresh order, so the restaurant could get two deliveries.

- **Exposed since** Oct 3 (CW, PPO: 93a360b) and Oct 19 (US Foods: 0601646).
- **Hit by a user?** Not visible, and it can't be ruled out: a retry reuses the order record and wipes the old message. Zero of 83 real orders in 120 days ended unconfirmed, which suggests unanswered submits are rare.

## What changed

In each of the three `confirm_unacknowledged_submit!` methods, the "still in the cart / still a draft" branch now raises `OrderUnconfirmedError` instead of `NotPlacedError`. The message tells the chef what we saw and to check the supplier before reordering. For example: "US Foods didn't confirm this order. It still showed in the US Foods cart right after we sent it, but US Foods may still be taking it. Check US Foods before reordering, so it is not placed twice."

| File | Change |
|---|---|
| `app/services/scrapers/us_foods_scraper.rb` | still IN_PROGRESS with lines → unconfirmed |
| `app/services/scrapers/chefs_warehouse_scraper.rb` | cart `itemCount > 0` → unconfirmed |
| `app/services/scrapers/premiere_produce_one_scraper.rb` | DRAFT or IN_REVIEW → unconfirmed |

`OrderUnconfirmedError` takes an existing production path; no new handling code:
1. `OrderPlacementService#handle_unconfirmed_submit` sets `pending_manual`, which isn't retryable.
2. `PlaceOrderJob#alert_not_placed` (kind `unconfirmed`) hands off to `OrderFailureAlertJob`.
3. That job always emails the chef and owner(s) for this kind.

The same three methods already took this path when the cart read empty.

## What did NOT change

- **Clear refusals after the submit keep "not placed" and Fix & Resubmit** (Carmin's choice): CW `success: false`, What Chefs Want's GraphQL refusal, Performance rejected or login turned away, Sysco's refusals.
- `OrderPlacementService`, `PlaceOrderJob`, every view, and Sysco / What Chefs Want / Performance code.
- Everything before the submit goes out: cart building, item refusals, cart checks, minimums, delivery dates.
- Placed read-backs: US Foods `fetch_submitted_order` and PPO `placed_at` still record the supplier's own number.

## Known side effect (PPO)

When PPO answers `submitOrder` with a GraphQL error (an explicit refusal), our client returns nil, exactly as on a timeout. The read-back then sees the draft and can't tell the two apart. So a PPO refusal at submit now also says "check the Premiere Produce app" instead of offering Fix & Resubmit.

Telling them apart would mean reading `api_client.last_error` right after the submit (a GraphQL message vs "HTTP nnn" vs nil on a timeout). **Considered and recommended against (Oct 20):** the PPO client (`premiere_produce_one_api.rb` `graphql`) returns nil whenever a response carries `errors`, *even if it also carries data*. A GraphQL answer can be "order placed" plus an error about something minor. If PPO's status read still showed DRAFT at that moment, the check would read the error as a refusal and offer Fix & Resubmit, which reopens the double order this fix closes. We have never seen PPO's submitOrder error shapes. Doing it safely means changing the shared PPO client, which every PPO call goes through: a much wider blast radius for a rare false alarm.

## Ordering impact

- Only runs in production, after our live submit went out, when the answer wasn't a confirmation and the immediate read still showed the order.
- In that moment the chef gets "check the supplier" plus the email, instead of "safe to try again" plus Fix & Resubmit. If the supplier doesn't have it, she uses Reorder on desktop, or rebuilds it in the builder on her phone (mobile has no Reorder by design).
- Cost: a false alarm when the supplier really never got the order. That's a look and some extra steps, never a wrong order.
- Nothing new is sent to any supplier. Dev dry-runs never reach this code.
- No migration and no data changes. Rollback is a revert.

## Tests

- **Changed** (they pinned the old "safe to try again" verdict):
  - `us_foods_ordering_spec.rb`: still in the cart after a timeout → unconfirmed. Another order's answer + still in the cart → unconfirmed.
  - `chefs_warehouse_scraper_spec.rb`: nil answer + full cart → unconfirmed.
  - `premiere_produce_one_checkout_spec.rb`: DRAFT → unconfirmed.
- **Added:** CW timeout + full cart → unconfirmed. PPO timeout + IN_REVIEW → unconfirmed.
- **Tripwire:** `spec/services/scrapers/no_safe_to_retry_after_submit_spec.rb` fails if "safe to try again" / "safe to retry" appears anywhere under `app/services/scrapers/`. It caught one of my own code comments during the build.
- **Unchanged and still passing** (they cover the rest of the path): CW `success: false` → not placed; `OrderPlacementService` unconfirmed → `pending_manual`, not retryable; clear refusal after submit → `failed`; `PlaceOrderJob` unconfirmed → alert kind `unconfirmed`.
- All 7 new or changed examples failed before the code change and pass after. The ordering-related files (172 examples) pass. Full suite on its own database (`restaurant_supplier_aggregator_test_oosrisks`), Oct 20: **2163 examples, 0 failures**.

## What did not work / was rejected

- **Turning every post-submit outcome into "check the supplier", clear refusals included** (one rule in `handle_generic_error`). That was Carmin's first direction. It reaches all six suppliers and changes cases where the supplier already said no plainly. Carmin chose the narrow version.
- **Re-reading several times for proof** (Sysco reads 3 times, 2 s apart). It would turn some alarms into confirmed orders but isn't needed to stop the double order. Not built.
- **Matching a re-filed US Foods order by date + items.** It could match an earlier order the same day and fake a confirmation. Id only.

## Open

- PPO: an explicit GraphQL refusal at submit now reads "check the app". Keeping it "not placed" was considered and recommended against (see "Known side effect"); revisit only if these alarms actually come up.
- Parked risks #6, #2, #3, #5, #7: see the plan doc.
