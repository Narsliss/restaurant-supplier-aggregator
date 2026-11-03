# Sign-up bot guard (honeypot + minimum fill time)

**Date:** 2026-11-03 · **Status:** live since `c4528d5` (2026-11-03). The robots.txt shipped
alongside it was removed in a follow-up; see "What did not work".

## Why

Early November 2026, the admin "Recent Signups" list showed the first two junk sign-ups in roughly
seven months of the app being up:

- Name `* * * <a href="https://myxa.cc/">SCAM SERVICE 24/7</a> * * * hs=4850…`, email on
  `merepost.com` (a disposable inbox). This is a known form-spam bot. It plants a link and a
  tracking hash in every form it finds, then searches for where the text resurfaces (emails it
  receives, pages that render it as a live link).
- "Matthew Anderson", `@mail.ru`. Ordinary-looking name, almost certainly the same kind of bot.

Neither account set anything up: no organization, no restaurant, no invites.

### What the attack did NOT achieve (checked)

- **Database:** names are stored as data in parameterized ActiveRecord queries. No controller or
  model builds SQL by interpolating params.
- **Page rendering:** the admin page showed the literal `<a href…>` text, because ERB escaped it.
  No view, helper or mailer renders a user, organization or location name with `raw` / `html_safe`.
- **Email:** sign-up sends no email (no `:confirmable`, no welcome email until a subscription
  exists), so the bot's throwaway inbox got nothing.

### Real exposure found (fixed in the follow-up, see "Follow-up: invite email cap")

An unpaid, unverified account can create an organization and send **unlimited invitation emails**
from our sending domain. The organization name and inviter name (both attacker-controlled) appear in
the subject and body. The invitations controller is deliberately exempt from the subscription check,
because owner onboarding *requires* inviting a team member before paying
(`ApplicationController#onboarding_incomplete?`). That makes it a spam relay that could damage
our sending reputation, and then order confirmations and 2FA emails would start landing in spam.

## What changed

1. **`SignupBotGuard`** (`app/services/signup_bot_guard.rb`), called from a `before_action` on
   `Users::RegistrationsController#create`:
   - **Honeypot `ep_hp`:** a text field inside a `sr-only` + `aria-hidden` wrapper, with
     `tabindex=-1`, `autocomplete="off"`, and ignore hints for 1Password, LastPass and Bitwarden.
     The name is deliberately meaningless so browsers don't autofill it. Any non-blank value
     rejects the submit.
   - **Minimum fill time `ep_ts`:** a signed render timestamp (`Rails.application.message_verifier`).
     It rejects submits under 3 seconds, and submits with no valid timestamp (a bot POSTing without
     loading the page). The timestamp has **no expiry**, so a form left open for days still works.
2. **On rejection:** no account is created. The form re-renders (422) with
   "We couldn't create your account just now. Please check your details and submit again.", the
   name and email kept, the passwords cleared, and a **fresh timestamp**, so the next submit
   goes through. An invited chef keeps the locked email and the "Join <org>" button.
3. **Logging:** each rejection writes
   `[SignupBotGuard] blocked reason=honeypot|too_fast|missing_timestamp ip=… email_domain=… invited=…`.
   Only the email *domain* is logged, not the full address.

## Blast radius

| Area | Affected? |
|---|---|
| Sign-up form (`POST /users`), including invited chefs | Yes. This is the only code path changed |
| Sign-in, password reset, supplier portal, CRM | No |
| Ordering, scrapers, background jobs, Stripe webhooks | No |
| Existing users and records | No. Nothing is validated or migrated |
| Page layout | No. The guard fields sit at the end of the form, so `space-y-5` doesn't shift visible fields |

**Worst case:** a real person is flagged (password manager fills the honeypot, or an autofilled
submit under 3 seconds). They see the error message and their next submit goes through, and the
log line shows it happened.

**Rollback:** revert the commit. There is no data or migration to undo.

## Verification

- `spec/services/signup_bot_guard_spec.rb`: pass/reject rules (exact 3s boundary, multi-day-old
  form, blank-whitespace honeypot, forged timestamp).
- `spec/requests/signup_bot_guard_spec.rb`: honeypot rendered hidden with no autofill; human
  submit creates the account; honeypot / no-timestamp / too-fast create nothing; a timer-tripped
  person succeeds on resubmit; **invited chef full flow** (accept link → form → join org); a
  timer-tripped invited chef keeps the invite form.
- Full suite: 2,242 examples, 0 failures.
- Browser (dev, localhost:3001): honeypot wrapper is 1×1px, clipped, absolutely positioned. A submit
  1s after load was rejected with the message shown, no row created, and the log line written.

## What did not work / was rejected

- **`public/robots.txt` with `Disallow: /`** shipped in `c4528d5` and was **removed** in a follow-up.
  It never took effect, for two reasons found only after deploy:
  1. Production returns 404 for files in `public/` (`/404.html` and `/favicon.ico` are 404 too;
     `config.public_file_server.enabled` depends on `RAILS_SERVE_STATIC_FILES`). The Railway env
     was not read, because of the Oct 21 breach caution.
  2. Cloudflare's **Bot Preference Sync** (managed robots.txt) serves its own file for
     enplacepro.app: AI-training crawlers blocked, `User-agent: * Allow: /` for search engines.
     If our file did reach it, Cloudflare would *prepend* its rules, and Google resolves an equal
     `Allow: /` vs `Disallow: /` as allow. So the sync would also have to be switched off.

  The mistake was recommending robots.txt from the repo ("there is none") without checking the
  live site, which already had Cloudflare's. Carmin decided to drop it: it only deters
  well-behaved crawlers, and spam bots ignore it. **Cloudflare's managed robots.txt is the one in
  force and was left unchanged.** If search delisting of the app is ever wanted, it needs a Rails
  route for `/robots.txt` (not `public/`) *and* Bot Preference Sync switched off.

- **No invites until paid:** rejected. Onboarding requires an invite before the subscription step,
  so this would block every new restaurant.
- **Captcha (Cloudflare Turnstile):** deferred. It needs a site-wide CSP change
  (`config/initializers/secure_headers.rb`), new secret keys on Railway (still under the Oct 21
  breach caution), and a third-party dependency that can block all sign-ups. Revisit only if junk
  keeps arriving with the honeypot live.
- **Honeypot at the top of the form:** moved to the bottom, because `space-y-5` would have added
  a 20px gap above the name fields.
- A first browser check "passed" a fast submit because the page had been open more than 3s before
  the scripted submit. That was correct behavior and a flawed test. The scratch dev account it
  created was deleted.

## Follow-up: invite email cap for unpaid orgs + Resend fix

### What a probe showed (throwaway request specs, not committed)

- An org with **no card** (`subscribed? == false`) sent invite emails. With the org named
  "Visit myxa.cc SCAM SERVICE 24/7", the subject read *"You've been invited to join Visit myxa.cc
  SCAM SERVICE 24/7 on EnPlace Pro"*.
- The existing **seat limit** (`OrganizationInvitation#organization_has_seats`, 5 seats for an
  unpaid org = owner + 4 pending) let only 4 of 20 straight invites through. But canceling an
  invite frees its seat: **cancel-and-reinvite x20 sent 20 emails to 20 people.**
- **Resend was broken for everyone:** `resend!` wrote `invitation_sent_at`, a column that has never
  existed (since `d90f977`, Feb 2026), so every Resend click (owner page *and* admin panel) raised
  `ActiveModel::UnknownAttributeError`.

### What changed

1. **`InviteSendLimit`** (`app/services/invite_send_limit.rb`): an unpaid org may send **10 invite
   emails per 7 days**, counting new invites *and* resends. The counter lives in `Rails.cache`
   (Solid Cache in prod), keyed by org, and expires 7 days after the *first* send (later sends
   don't extend it). Canceling doesn't give a send back. `subscribed?` orgs (paid or
   complimentary) are never counted or limited.
2. `Organizations::InvitationsController#create` and `#resend` check the cap **before** saving or
   sending, so a blocked invite takes no row and no seat. Blocked: org page banner (or the wizard
   form error) "You've sent the most invitations allowed before subscribing. Subscribe to invite
   more people." Logged as `[InviteSendLimit] blocked action=… org=… user=… sent=… ip=…`.
3. `OrganizationInvitation#resend!` no longer writes the missing column. This fixes Resend for
   owners, and for the admin panel's resend (`Admin::OrganizationsController`, super-admin only,
   not capped).

### Why 10 and no prod query

The seat limit already caps a real unpaid restaurant at 4 pending invites at once, so a legitimate
onboarding can't need many sends. 10 leaves room for typos and resends. That made the prod invite
count (which needed Railway access) unnecessary.

### Blast radius

| Area | Affected? |
|---|---|
| Unpaid orgs sending invites (onboarding) | Yes. Capped at 10 sends / 7 days |
| Paid and complimentary orgs | No. Never counted |
| Resend button (owners + admin) | Yes. Fixed, was raising an error |
| Accepting an invite, sign-up, ordering, scrapers, jobs | No |
| Schema | No migration |

**Worst case:** an unpaid owner who really needs more than 10 sends in a week sees "Subscribe to
invite more people", which is already the next step in onboarding.

**Known limits:** Solid Cache can evict entries under size pressure, which would reset an org's
count early. That's acceptable for an abuse cap, but it isn't an audit record. In dev the cache is
`:null_store` unless `tmp/caching-dev.txt` exists, so the cap never triggers in dev.

### Verification

- `spec/services/invite_send_limit_spec.rb`: blocks at 10, per-org, the 7-day window runs from
  the first send, paid orgs never counted.
- `spec/requests/invite_send_limit_spec.rb`: the first onboarding invite works; cancel-and-reinvite
  stops at exactly 10 emails and the blocked invite isn't saved; the wizard shows the message
  (422); resends count and are blocked at the cap; a complimentary org sends 15 unhindered;
  **Resend regression** (email queued, expiry extended).
- Against a real `SolidCache::Store` on the dev DB: 10 sends → `allowed? == false`. The test key
  was deleted afterwards.
- Full suite: 2,251 examples, 0 failures.

## Follow-up: plain-text names

### What changed

- **`PlainTextNameValidator`** (`app/validators/plain_text_name_validator.rb`) rejects `<`, `>`,
  `http://`, `https://` and `www.` (case-insensitive), with the message "can't contain links or the
  < > characters".
- It's applied to `User#first_name` / `#last_name`, `Organization#name` and `Location#name`, each
  **only when that attribute changes** (`if: :<attr>_changed?`). Existing rows are never re-checked,
  so a legacy name can't make an unrelated save fail.
- Bare domains (`myxa.cc`) are deliberately allowed, because too many real names contain a dot. The
  Nov 3 bot's name is still caught by its `<a href=` and `https://`.

### Where names get saved (mapped before building)

Sign-up and profile edit (Devise), organization create and edit (including the wizard; create already
rescues `RecordInvalid` and re-renders), restaurant create and edit, CRM/admin salesperson accounts,
CRM `Crm::Lead#convert_to_organization!`, seeds, and `Dev::CompanySandbox`. No job, scraper or
ordering path renames any of these.

### Blast radius

Only forms where a person types a name; each re-renders with the error. No migration. Ordering,
scrapers and jobs are untouched. **Worst case:** a real person whose name contains `<`, `>` or
`www.` is asked to change it.

### Verification

- `spec/validators/plain_text_name_validator_spec.rb`: 17 real-world names pass (O'Brien, José
  Álvarez, Đặng, Bar & Grill, St. Elmo's, Eat.Drink, Etxe Cincinnati…); 6 link/HTML strings are
  rejected; a bare domain passes.
- `spec/models/plain_text_names_spec.rb`: for each model, a bad name is rejected on create and
  rename, and **an existing row with a bad legacy name still saves** when another field changes.
- `spec/requests/signup_bot_guard_spec.rb`: the Nov 3 bot's exact name, through the real sign-up
  form with valid bot-guard fields, creates no account (422, message shown).
- Full suite: 2,283 examples, 0 failures.
- **Not checked:** how many existing prod names already match. The read-only prod lookup
  (`railway ssh`) was blocked by the auto-mode safety check. Matching rows are grandfathered either
  way.

## Open items

1. **The two bot accounts are still in prod.** The read-only lookup was blocked (see above). The
   admin panel has no delete or lock action for users, and Claude doesn't hard-delete prod data, so
   any deletion is Carmin's, from a Rails console. They own nothing per Carmin's own check.
2. **Noticed, not changed:** CRM "Convert lead" (`Crm::Lead#convert_to_organization!`) calls
   `Organization.create!` with only name/city/state, but address and zip are required, so it
   looks like it raises `RecordInvalid` on every use.
3. After deploy, watch the web logs for a week: `[SignupBotGuard]` (a `too_fast` with
   `invited=true` would be the first false positive) and `[InviteSendLimit]` (a block on a real
   restaurant would mean 10 is too low).
4. **Noticed, not changed:** the org page prints any `?error=` text from the URL. It's escaped, so it
   isn't XSS, but anyone could craft a link that shows a signed-in owner a fake message on our page.
