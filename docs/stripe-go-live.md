# Stripe go-live: checklist and how billing actually works

*Written Oct 15, 2026 from a read of the billing code on `main` (e5b11df). Updated the same day after the fixes on branch `stripe-go-live-fixes` (see "Status" below). Part 3 describes behavior **after** those fixes, unless it's marked "before".*

Production has been on Stripe **test** keys since launch. No real money moves, but the webhook → email pipeline is live, so actions on test subscriptions still email real chefs. This doc covers:

1. what you need to set up in Stripe and Railway,
2. what has to change in the code before live mode is safe,
3. how cancellations, renewals, proration, complimentary access and trials behave.

## Decisions (Carmin, Oct 15 2026)
- **Alfio's moves from comp to paid, charged the day he enters his card.** No dated free period. He subscribes himself from Subscription → **Switch to paid** while still on comp, and comp ends automatically once his subscription is active. Nobody at Alfio's sees the paywall. Don't use the admin **Revoke** button for this.
- **Failed card:** keep access while Stripe retries, for a **2-week** window. Then Stripe cancels and the paywall takes over. Set this in Stripe (1g: Smart Retries, 2 weeks, then cancel the subscription).
- **Price (Oct 19):** $149/month base, $10/month per seat over 5. Alfio's 8 seats = $179/month.
- **Trial (Oct 19):** new restaurants get **60 days free**, card entered at checkout, first charge on day 61. Only a restaurant's **first** subscription gets it: no trial for a comp org switching to paid (Alfio's is charged the same day) or for a returning customer (`Organization#checkout_trial_days`, which asks live Stripe for the customer's subscription history). The pricing page names the exact first-charge date; the sign-up page no longer promises "no credit card required".
- **Support email (Oct 19):** carmin@las-noches.com.
- **Legal pages (Oct 19):** the Terms of Service, Privacy Policy and Support pages live on the marketing site: `https://enplacepro.com/terms`, `/privacy`, `/support` (repo enplacepro-website, change record `docs/support-privacy-pages.md`). The app's `/terms` is a 301 redirect there. In Stripe use those URLs: public details (support URL `…/support`, privacy `…/privacy`) and the customer portal's terms link (`…/terms`).
- Still open (only needed on switch day): the other four orgs, Stripe receipts, Ohio sales tax.

## Status (branch `stripe-go-live-fixes`, rebased on main Oct 19, not yet committed)
| Blocker | State |
|---|---|
| 1. Past-due lockout + duplicate subscription | **Fixed.** Past-due keeps access. Checkout is refused when our DB *or Stripe* shows a live subscription. A red "Payment failed / Update card" bar shows to the owner, desktop and mobile. The old yellow banner called a route helper that doesn't exist and would have errored on every page. |
| 2. Payment-failed / 3DS emails never send | **Fixed.** Invoices read `parent.subscription_details.subscription`. |
| 3. Test customer IDs break checkout | **Fixed.** A missing or deleted customer is replaced with a new one automatically. Checkout and portal errors now show a message instead of silently bouncing. |
| 4. Test subscriptions grant free access forever | **Fixed (Oct 19)**, as an admin page instead of a migration: **Admin → Revenue → Stripe test-mode cleanup** (`/admin/billing_cutover`). It shows whether the app is on the LIVE or TEST key and previews which subscriptions and customer IDs it will retire. It checks each one against live Stripe first, so a real subscription is never touched, and it refuses to run on a test key. No emails, and it's safe to run twice. A page beats a migration because you control the moment: nothing depends on the push and the key change landing in a particular order. |
| 5. Comp orgs can't subscribe | **Fixed.** "Switch to paid" on the Subscription page. The pricing page shows the real monthly total including extra seats. Comp ends on its own when the subscription is active. |
| 6. Support email is the old brand | **Fixed (Oct 19).** One setting, `config/initializers/support_email.rb` (override with `SUPPORT_EMAIL`), currently `carmin@las-noches.com` per Carmin. It's used on the dashboard, Subscription page and Terms, and as the **reply-to on billing emails**: they say "just reply" but come from `noreply@`, so replies used to go nowhere. A spec fails if an old `@supplierhub.` address returns to any view. |
| 7. Invoices failing "User must exist" | **Fixed for the likely cause.** Invoices now resolve through their subscription before the customer ID. An invoice that matches nothing is reported, not crashed, and the admin dashboard shows a red alert for failed or unmatched Stripe events from the last 7 days. The exact prod cause is still unconfirmed. |

Also fixed: subscriptions are attributed to the org in the Checkout metadata, not the user's currently selected restaurant. Reactivate only touches the org's live subscription. Admin "Extend trial" counts from today when the old trial already ended. The cancel email now says access *has ended* and links to resubscribe. The admin Revoke confirmation spells out the instant lockout. The plan box shows the seat pricing instead of "Users: Unlimited".

## Prod billing census (read-only, Oct 15 2026)

- **Config:** test key, `STRIPE_TRIAL_DAYS=0`, webhook secret and both price IDs set.
- **5 organizations, all with a test-mode Stripe customer ID**, so blocker 3 affects every one of them:

| Org | Billing state | Usage | At cutover, as built |
|---|---|---|---|
| Alfios buon cibo (7) | **Comp** since Jun 4 ("Granted by admin"). Old test sub canceled Jun 4. | **The real customer:** 33 orders in 30 days, 105 total, 9 members, 8 seats | Comp continues forever. If converted: $149 + 3 extra seats = **$179/mo** |
| Tres Noches Restaurant Group LLC (6) | Test sub **active** (since Aug 13) | 0 orders ever, 2 members | Free access forever (blocker 4) |
| BIG ICE LLC (11) | Test sub **active** (since Aug 25) | 0 orders, 1 member | Free access forever (blocker 4) |
| The Empanada's Box (8) | Test sub canceled Aug 13 | 0 orders, 1 member | Paywalled. Checkout would fail (blocker 3). |
| Alfios Buon Cibo (10), *second org with nearly the same name* | No sub, no comp | 0 orders, 1 member, created Aug 24 | Paywalled. Checkout would fail (blocker 3). |

- **Invoices:** 7 rows, all paid (test money), and **all 7 have no subscription link.** Blocker 2 is confirmed. The latest invoice payload has `parent.type = subscription_details` and no top-level `subscription`.
- **12 invoice webhooks failed with "Validation failed: User must exist"**, most recently Oct 13 (the 13th is Tres Noches' renewal day). The invoice's Stripe customer doesn't match any org's saved customer ID, so the row never saves. See blocker 7.
- **The test webhook endpoint has never delivered a `customer.subscription.updated`**, even though two subscriptions have renewed. It's almost certainly not subscribed to that event. As a result, our period dates are stale (Tres Noches still shows a period ending Sep 13). The live endpoint must include all 14 events in 1e.
- 0 `invoice.payment_failed` events ever, so the dunning path has never run on prod.

---

## Part 1: What you need from Stripe (your side, in the dashboard)

You have to do these yourself. They involve your SSN, bank account and live secret keys, which I can't enter for you. All of them except 1a can be done now, in parallel with the code work.

### 1a. Activate the account (Settings → Business → Activate payments)
- [ ] Legal entity name, entity type, **EIN**, business address
- [ ] Industry: Software / SaaS. Product description, e.g. "Subscription software that lets restaurants compare supplier prices and place orders."
- [ ] Website: `https://enplacepro.app`. Stripe checks that it shows pricing, terms and a way to contact you.
- [ ] Representative: name, DOB, home address, last 4 of SSN
- [ ] **Bank account for payouts**
- [ ] Turn on 2-step login for the Stripe account

### 1b. Public details (Settings → Business → Public details)
- [ ] Statement descriptor, which is what shows on chefs' card statements: `ENPLACEPRO`. **Keep it to 10 characters or fewer**, because when a free trial converts, Stripe overwrites everything after character 10 with `* TRIAL OVER` (card-network rule). An unrecognizable descriptor is the #1 cause of "what is this charge" chargebacks.
- [ ] Support email + phone. **This must be a real inbox.** See blocker 6: the app currently tells chefs to email `support@supplierhub.com`.
- [ ] Terms URL: `https://enplacepro.app/terms`. Privacy URL: there is no separate privacy page. Privacy is section 8 of the terms. Use `https://enplacepro.app/terms` for now, or ask me to add a `/privacy` page.

### 1c. Branding (Settings → Branding)
- [ ] Logo, icon, brand color. These apply to Checkout, the customer portal, receipts and invoices.

### 1d. Live products and prices (Product catalog, with the **Test mode toggle OFF**)
Test-mode products don't carry over. Recreate them:
- [ ] Product **EnPlace Pro**, price **$149.00 USD, recurring monthly** → copy the `price_…` ID (price raised from $99, Carmin Oct 19)
- [ ] Product **Additional seat** (or a second price on the same product), **$10.00 USD, recurring monthly, per unit** → copy the `price_…` ID
- Both prices **must** be monthly USD, or Checkout rejects the combination.
- [ ] Optional: **coupons/promotion codes**. Checkout already shows an "Add promotion code" box (`allow_promotion_codes: true`). This is one way to move comp customers over (see Part 3).

### 1e. Live webhook endpoint (Developers → Webhooks → Add endpoint, live mode)
Don't copy the test endpoint's event list. It's missing at least `customer.subscription.updated` (see the census).
- [ ] URL: `https://enplacepro.app/webhooks/stripe`
- [ ] **API version: `2026-02-25.clover`**. This must match `config/initializers/stripe.rb`.
- [ ] Events (the 14 the app handles):
  `checkout.session.completed`,
  `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`,
  `customer.subscription.paused`, `customer.subscription.resumed`, `customer.subscription.trial_will_end`,
  `invoice.paid`, `invoice.payment_failed`, `invoice.payment_action_required`, `invoice.created`, `invoice.finalized`,
  `customer.created`, `customer.updated`
- [ ] Copy the endpoint's **signing secret** (`whsec_…`). It is different from the test one.
- [ ] After cutover: **disable the test-mode endpoint** that points at enplacepro.app. Its signatures will fail against the live secret, and Stripe will otherwise keep retrying and emailing you about it.

### 1f. Customer portal (Settings → Billing → Customer portal, **live mode**)
Live mode needs its own saved portal configuration. Until you save one, the app's "Manage Billing" button fails silently.
- [ ] Allow: update payment method, view invoice history, update billing email/address
- [ ] Cancellations: allow, **at end of billing period**, no proration (this matches the app's own Cancel button and Terms §5)
- [ ] **Turn OFF "switch plans" and "update quantities".** The app manages seat quantity itself (`Stripe::SeatSyncService`). If chefs can change quantity in the portal, the app's seat count and Stripe's drift apart.
- [ ] Business info: terms + privacy URLs, headline

### 1g. Subscription and email settings (Settings → Billing → Subscriptions and emails)
- [ ] **Failed payments → Smart Retries**, about a 2-week window, then **cancel the subscription**. Decision for you; my recommendation is in the questions at the end.
- [ ] **Successful payment receipts: ON** (recommended). The app sends no receipts, and restaurants want them for bookkeeping.
- [ ] Failed payment emails / expiring card emails: decide (see blocker 2: the app's own failed-payment email is currently broken).
- [ ] **Trial-ending reminder: ON** (Settings → Billing → Subscriptions and emails → trial reminder with "Link to a Stripe-hosted page"). Card networks require a reminder before a card-on-file free trial converts; Stripe's goes out **7 days** before and includes the cancel link. The app's own email (3 days before, on `trial_will_end`) is an extra. *(Changed Oct 19: with a 60-day trial this must be on.)*

### 1h. Sales tax: ask your accountant before the first live charge
- [ ] Ohio generally treats SaaS sold to businesses as taxable. Confirm with your accountant. If it applies, you'd register with Ohio, turn on **Stripe Tax**, and I'd add `automatic_tax` + address collection to Checkout (small change).

### 1i. Railway variables (set at cutover time, not before)
Set on **both** `pretty-friendship` (web) and `worker` so they never disagree. Saving variables triggers a redeploy.

| Variable | Value |
|---|---|
| `STRIPE_SECRET_KEY` | `sk_live_…` (or a restricted `rk_live_…` key) |
| `STRIPE_WEBHOOK_SECRET` | the live endpoint's `whsec_…` |
| `STRIPE_MONTHLY_PRICE_ID` | live `price_…` for $149 |
| `STRIPE_SEAT_PRICE_ID` | live `price_…` for $10 seat |
| `STRIPE_TRIAL_DAYS` | **`60`** (currently `0` in Railway; the code default is now 60) |

`STRIPE_SUCCESS_URL` / `STRIPE_CANCEL_URL` exist in config but aren't used. The controller builds its own URLs.

---

## Part 2: What has to change in the code first (my side)

These are **blockers**. Going live without them means real double-charges, missing dunning emails, or customers who can't pay.

### Blocker 1: A failed card locks the restaurant out *and* invites a second subscription
`Organization#current_subscription` only looks at `active`/`trialing` rows (`app/models/organization.rb:35`). `Subscription#allows_access?` was written to include `past_due` as a grace period, but it never sees past-due rows. So when a card declines:
- The org loses access on the next click. Every page except the dashboard redirects to the pricing page.
- `/subscription` shows "No Active Subscription → Subscribe Now".
- The owner clicks it and Stripe creates a **second** subscription on the same customer, while Stripe is still retrying the first. If a retry succeeds, they're billed twice.

**Fix:** treat past-due as "has a subscription" (keep access during Stripe's retry window). Never offer a new Checkout to an org that already has a live Stripe subscription; send them to the billing portal to fix the card. Add an unmissable in-app banner (mobile too) while past-due.

### Blocker 2: The payment-failed and 3D Secure emails can never send
Since Stripe API `2025-03-31.basil`, invoices no longer have a `subscription` field. It moved to `invoice.parent.subscription_details.subscription` ([Stripe changelog](https://docs.stripe.com/changelog/basil/2025-03-31/adds-new-parent-field-to-invoicing-objects)). We pin `2026-02-25.clover`, so `Invoice.sync_from_stripe` never links an invoice to its subscription (`app/models/invoice.rb:38`). Both emails are guarded by `if invoice.subscription` (`app/services/stripe/webhook_handler.rb:216,228`), so they silently never send. The admin org page's invoice list joins through `subscription` and comes up empty for the same reason.

**Fix:** read `parent.subscription_details.subscription`, falling back to the old field. Add a spec using a clover-shaped payload. **Confirmed on prod Oct 15:** 7 of 7 invoices are unlinked.

### Blocker 3: Test-mode customer IDs will break checkout for existing orgs
Every org that ever went through test Checkout has a test-mode `stripe_customer_id`. With a live key, `Stripe::Customer.retrieve` on that ID raises "No such customer". `SubscriptionsController#create` rescues it and silently bounces the owner back to the pricing page. They click Subscribe, nothing happens, forever. The billing portal fails the same way.

**Fix:** if the stored customer doesn't exist in the current mode, create a fresh one. Plus a cutover step that clears test IDs.

### Blocker 4: Test-mode subscription rows keep granting access after cutover
Test subscriptions marked `active` in our DB will never get another webhook once the secret is live. They'd grant free access indefinitely, and seat syncs against them would fail and email you "revenue leak" alerts.

**Fix (built):** `Billing::TestModeCutover` + the admin page above. Per-org decisions (comp or not) are made separately in the admin Organizations page.

### Blocker 5: Complimentary orgs can't subscribe on their own
`/subscription/new` redirects anyone `subscribed?` to `/subscription`. Comp orgs count as subscribed but have no subscription row, so `/subscription` shows "Subscribe Now", which links back to `/subscription/new`. That's a redirect loop. Today the only way off comp is to revoke it, which paywalls them instantly with no warning.

**Fix:** depends on the comp off-ramp you choose (Part 3).

### Blocker 6: Support contact points at a dead brand
`support@supplierhub.com` (subscription page, dashboard ×2) and `support@supplierhub.app` (terms). Once real money moves, a chef who can't reach you files a chargeback instead.

### Blocker 7: Some renewal invoices fail to save ("User must exist")
Found in the prod census. `Invoice.sync_from_stripe` finds the org by `organizations.stripe_customer_id`. When the invoice's customer doesn't match (12 events so far, latest Oct 13), there's no user, `belongs_to :user` fails, and the invoice is lost. If this happens to a live customer, it also loses their failed-payment email. The root cause isn't pinned down yet. The likely suspect: the subscription was created under a different Stripe customer than the one saved on the org. One more read-only prod query (the customer on those events vs each org's saved ID) will settle it.

**Fix:** fall back to the subscription's org (via `parent.subscription_details`) when the customer lookup misses, and make the unmatched case alert loudly instead of failing quietly.

### Should-fix (not blockers)
- ~~**Cancel email wording.**~~ *Fixed:* it's sent when access ends, and now says so and links to resubscribe. It used to say "reactivate any time". Still nothing emails the owner when they *schedule* a cancel.
- ~~**Trials repeat.**~~ *Fixed Oct 19:* only a restaurant's first subscription gets the trial.
- ~~**Admin "Extend trial" can error.**~~ *Fixed:* it now counts from today when the old trial already ended.
- **Seat billing drift.** Seats are synced only when an invite is *accepted* or a member is *deactivated*. Pending invites count as paid seats. A revoked or expired invite doesn't un-bill until the next sync. See Part 3.
- ~~**The subscription page header always said "$99.00/month".**~~ *Fixed Oct 19:* `amount_cents` and `interval` now sync from Stripe (base + seat quantity, before discounts), so the page and the trial-ending email show what Stripe actually bills.
- **Admin MRR** still counts trialing subs as revenue (amounts now include seats).
- **Stripe Ruby gem is 12.6.0** while we pin a 2026 API version. It works because the objects are dynamic, but the gem's typed helpers predate basil/clover. Upgrade it separately, later.

---

## Part 3: How billing behaves today

### The plan
- **$149/month** base (raised from $99 on Oct 19). One plan, no annual option, no upgrades or downgrades. The amount customers *see* is `monthly_amount` in `config/initializers/stripe.rb`; what Stripe *charges* comes from the live price ID. Change both together.
- **5 seats included.** A seat is any active non-owner member **or pending invitation**. The owner is free.
- **Seat 6+ is $10/month each**, added and removed automatically.
- Before subscribing, an org can invite up to 5 people. Once subscribed (or comp), there's no seat cap; extras are just billed.
- Only **owners** can subscribe, cancel, reactivate or open the billing portal.

### Signing up (Checkout)
Owner clicks Subscribe → Stripe-hosted Checkout → enters card → back to the app.
- **No trial (`STRIPE_TRIAL_DAYS=0`):** charged $149 (+ seats over 5) immediately. That date becomes their monthly billing day.
- **With the trial (60 days, first subscription only):** the card is collected **up front** but not charged; the pricing page states the first-charge date. Comp orgs switching to paid and returning customers are charged immediately. There is no card-free trial.
- The welcome email goes to the owner, and you get a "new signup" email.

### How a trial expires and starts charging
Assuming trials are on (N days):

| When | What happens | Who does it |
|---|---|---|
| Day 0 | Card saved, subscription `trialing`, full access | Stripe Checkout + our webhook |
| During trial | `/subscription` shows "X days remaining". No banner anywhere else in the app. Adding seats costs nothing yet. | — |
| Day N − 3 | Stripe fires `trial_will_end` → our email "Your trial ends in 3 days" | Stripe → us |
| Day N | Stripe bills $149 + seats, charges the saved card automatically → status `active` → billing day = day N every month | Stripe |
| Day N, card fails | Status → `past_due`. Access continues, the owner sees a red "Payment failed / Update card" bar and gets the payment-failed email, and Stripe retries for 2 weeks. If every retry fails, Stripe cancels → "subscription has ended" email → paywall. *(Before the fixes: instant lockout, a duplicate-subscription risk, and no email.)* | Stripe + us |
| Canceled during trial | Ends at trial end, never charged | Stripe |

Changing `STRIPE_TRIAL_DAYS` only affects **new** Checkouts. It never changes existing subscriptions.

### Renewals
Fully automatic in Stripe. On the billing day each month, Stripe drafts the invoice (base + current seat quantity + any seat proration from the last month). It charges the card about an hour later and sends us `invoice.created` / `.finalized` / `.paid` and `customer.subscription.updated`, which update our rows. The app does nothing on its own schedule; there's no renewal job.
- A billing day of the 29th, 30th or 31st falls on the last day of shorter months (Stripe handles it).
- Expired or replaced cards are often refreshed automatically by the card networks through Stripe. Stripe can also email the owner about an expiring card (setting 1g).
- **Price changes:** Terms §5 promises 30 days' notice. Nothing is built for this. A price change means a new Stripe price and migrating each subscription.

### Proration: where it happens and where it doesn't
- **Base plan: never prorated.** The first charge is a full $149 on signup day (or trial end), not prorated to the 1st of the month. There's nothing to upgrade or downgrade to.
- **Seats: the only proration.** When a 6th+ seat is added or removed, the app updates the Stripe seat quantity with Stripe's default behavior. The prorated amount **lands on the next monthly invoice**, not as an immediate charge.
  - *Example:* billed on the 1st; 6th seat accepted on the 16th → next invoice ≈ $149 + $10 (next month) + ~$5 (half of this month) = **~$164**.
  - *Removing* that seat on the 16th → about $5 credit on the next invoice.
  - Seat changes during a trial cost $0.
- **Cancellations: no proration, no refund.** Cancel takes effect at the end of the paid month (Terms §5: fees are non-refundable). Refunds, if you ever want to give one, are done by hand in the Stripe dashboard (Payments → the charge → Refund).
- **Admin "Extend trial" on a paid sub** puts it back into `trialing` until the new date. By Stripe's default it credits the unused part of the current paid month onto the next invoice, so it works as "give them X free days".
- **Seat sync triggers (exactly):** invite accepted → sync; member deactivated → sync. Not synced: invite *sent* (but it's counted at the next sync), invite revoked, invite expired, member reactivated. So the Stripe quantity can lag reality until the next accept or deactivate. Pending invites are billed as seats.

### Cancellations: every path

| Path | What it does | Access ends | Email |
|---|---|---|---|
| Owner → /subscription → **Cancel Subscription** | Confirm dialog → `cancel_at_period_end` | End of paid period. Yellow "Subscription canceling" banner + **Reactivate** button until then. | None when scheduled; "canceled" email when it ends |
| Owner → **Manage Billing** (portal) | Whatever you allow in 1f (recommend: end of period only) | Per portal setting | Same |
| You → /admin/organizations/:id → **Cancel** | `cancel_at_period_end` only | End of period | Same |
| You → Stripe dashboard | Can cancel immediately, optionally prorate/refund | Immediately if you choose | **"Canceled" email goes to the real chef** |
| Card fails, retries exhausted | Stripe cancels (per 1g) | When Stripe gives up | Same |

After cancellation, all data (lists, matches, orders, credentials) stays. Resubscribing is a fresh Checkout: a new subscription and a new billing day, with **no** second trial.

### Complimentary access
- Super admin grants it at `/admin/organizations/:id` with a reason. It records who and when.
- **It's purely an app flag. Nothing exists in Stripe.** The org bypasses the paywall, gets unlimited free seats, and seat sync skips it.
- **No end date, no warnings, no emails.**
- **Revoking (admin button) is instant.** Everyone at the org lands on the pricing page on their next click, until the owner pays. No email tells them why. Orders already submitted still go through, and background syncs keep running.
- **Switching to paid without interruption (chosen for Alfio's):** the owner opens Subscription → **Switch to paid**. The pricing page states the monthly total including extra seats ($179 for Alfio's 8 seats). Checkout charges the card that day, and comp ends automatically the moment the subscription is active (`Organization#end_complimentary_for!`, called on every subscription sync). The admin page shows this hint next to the Revoke button.
- Comp and a paying subscription never coexist. Any synced subscription that grants access ends comp. To make a paying restaurant free, cancel its subscription first, then grant comp.

Other ways to move comp customers, not built: a dated free period (Checkout with a fixed `trial_end`), or a 100%-off promotion code (zero code, since Checkout already accepts codes).

---

## Part 4: Switch-day runbook

Before: Part 1 done in Stripe (live mode), and my branch pushed with your OK. The push deploys the fixes while still on test keys, which is safe (see "blast radius" below).

1. **Railway → `pretty-friendship` → Variables:** set `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_MONTHLY_PRICE_ID`, `STRIPE_SEAT_PRICE_ID`, `STRIPE_TRIAL_DAYS`. Railway redeploys.
2. **Railway → `worker` → Variables:** the same five. Railway redeploys.
3. **Admin → Revenue → Stripe test-mode cleanup.** The badge must say **LIVE**. Review the list (expected: Tres Noches and BIG ICE subscriptions, plus test customer IDs on all five orgs). Click **Clean up test-mode billing**. Alfio's complimentary access is unaffected.
4. **Alfio, in the room:** Subscription → **Switch to paid** → pricing page shows **$179/month** → Stripe Checkout → back in the app. His complimentary flag clears itself.
5. **Check:**
   - Stripe → Developers → Webhooks → the live endpoint shows successful deliveries.
   - Admin → Organizations → Alfio's shows an active subscription and no "Complimentary" badge.
   - The welcome email arrived.
   - **Manage Billing** opens the Stripe portal.
6. **Stripe, test mode:** disable the old webhook endpoint that points at enplacepro.app.

If anything in steps 3–5 goes wrong: grant Alfio complimentary access again from the admin page (instant), and tell me what you saw.

**Blast radius of the push itself:** nothing in ordering, scrapers or jobs changed, and there's no database migration. On test keys, the visible differences are a "Switch to paid" link for complimentary orgs, the cleanup page (which refuses to run), and a red admin-dashboard alert about unmatched Stripe events (expected noise until the switch). Rollback = revert the commit.

## Still open
- Tres Noches, BIG ICE, The Empanada's Box, and the second "Alfios Buon Cibo" org: comp, pay, or leave paywalled?
- Stripe receipts on/off (recommended on).
- Ohio sales tax (accountant).
- Support email is Carmin's own inbox for now; change `SUPPORT_EMAIL` when a shared inbox exists. Use the same address in Stripe's public details so receipts match.
- Not built: seat-sync drift (pending invites billed; revoked or expired invites not un-billed), admin MRR accuracy, Stripe gem upgrade.
