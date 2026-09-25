# Fix: US Foods login fails for phone-only accounts (Sep 25 2026)

## What happened
A chef (US Foods user `cchandler360`) could not validate their US Foods credential. Three
attempts (14:15, 14:18, 14:22 UTC) all ended with:

> Could not complete login on US Foods: Login did not redirect back to usfoods.com after MFA
> (stuck at: https://identity.usfoods.com/…/api/SelfAsserted/confirmed?…)

Another US Foods account logged in normally in the same window (14:16 → redirected 14:18), so
US Foods' B2C flow itself had not changed.

## Root cause
`UsFoodsScraper#handle_mfa_selection` chose Email whenever `button#Email` existed. For accounts
with **no email on file**, B2C still renders that button, labelled **"Add your email address"**.
Worker log:

```
MFA options — Text: ***-***-1017, Email: Add your email address
Selected MFA method: Email
```

Choosing it starts B2C's email-enrollment journey, not a sign-in. After the code step the page
stayed on "Enter your one-time passcode" with a form whose action is `JavaScript:void(0)`, so
all 15 `click_b2c_continue_button` attempts re-submitted a no-op form and the flow never
redirected. The chef was also told "US Foods has sent a verification code to Add your email
address".

## Fix
New `choose_mfa_method`: use Email only when the label contains `@` (a real masked address,
e.g. `c*******4@gmail.com`); otherwise use Text/SMS (prompt names the masked phone,
`two_fa_type: 'sms'`). If neither is usable, it raises a clear error.

Specs: `spec/services/scrapers/us_foods_scraper_spec.rb` `#choose_mfa_method`.

## Ordering impact
Login only. No change to cart, checkout, submission or price verification. PlaceOrderJob
re-logins benefit from the fix for these accounts.

## What did NOT work / not tried
- The post-MFA Continue-button loop was not the problem. It was clicking correctly; there was
  nothing to continue to.
- The SMS path has not been live-verified on a phone-only account. It uses the same
  `#code1..#code6` inputs as email, per the original B2C recon.

## Open items
- The user-facing error dumps the entire B2C URL (tx state + diags trace) into the credential
  card. Should show a short message and keep the URL in logs only.
- The `two_fa_type` in the TwoFactorChannel broadcast is not read by the front end today.
