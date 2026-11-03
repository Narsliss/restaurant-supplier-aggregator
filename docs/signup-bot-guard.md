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

### Real exposure found (NOT fixed here, see Open items)

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

## Open items

1. **Invite cap for unpaid organizations** (the real exposure above). It needs a generous limit set
   from real prod invite counts before payment. The dev DB has 3 test orgs, so it can't answer
   that. Reading prod needs Carmin's OK (Railway caution).
2. **Optional:** reject URLs / `<` / `>` in first/last/organization names, scoped to changed values
   (`if: :name_changed?`) so existing rows never fail a later save.
3. **Delete the two bot accounts** in prod: Carmin's call. They own nothing.
4. After deploy, watch `[SignupBotGuard]` in the web logs for a week. A `too_fast` with
   `invited=true` would be the first sign of a false positive.
