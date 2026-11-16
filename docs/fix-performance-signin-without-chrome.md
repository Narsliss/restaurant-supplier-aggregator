# Fix: sign Performance in without Chrome

**Date:** 2026-10-21
**Branch:** `perf-dates-auth`, with the 24-hour renewal and the delivery-days alert fix (docs/fix-performance-dates-session-expired.md). Not committed or pushed.
**Recon:** docs/recon-performance-http-signin.md. A real sign-in over plain HTTP worked on D'oro's login on Oct 21.

## Why

Performance logins end 24 hours after a real sign-in, so every login needs one real sign-in a day. The 24-hour renewal did that sign-in with Chrome (~250 MB a launch). Carmin, Oct 21: at 10,000 users "that is a whole LOT of chrome tabs opening", about 2,250 a day for Performance alone.

## What changed

**`PerformanceApi#sign_in`** signs in with the login's stored email and password using the five requests B2C's hosted page makes, over plain `Net::HTTP` with a small cookie jar:
1. authorize, with PKCE S256
2. `SelfAsserted`, with the page's CSRF token
3. `CombinedSigninAndSignup/confirmed`, not followed: the redirect carries the code
4. the token exchange, with the code verifier and the SPA's `Origin`

It loads the tokens, `refresh_token_expires_at` included, and saves them:
- into the stored MSAL entries in place, so a browser restore still finds its account data
- or, when there are no entries, into two entries of our own (`SIGNED_IN_ACCESS_KEY`, `SIGNED_IN_REFRESH_KEY`) in the shape `restore_session` reads

It returns one of:
- `:signed_in`
- `:rejected`: B2C refused the email/password, and its message is logged
- `:failed`: anything else (the page changed, no code, the token step refused, a network error)

It never logs or raises with a password, token, cookie, code or CSRF value; a spec checks the log.

**`persist_tokens!`:** its loop that writes into the MSAL entries became `write_tokens_into`, shared with `sign_in`. Its behaviour is unchanged, and its existing specs pass.

**`PerformanceScraper#http_sign_in`** calls `sign_in` and marks the login active on success. It never raises. A password Performance refused isn't sent again over HTTP by the same scraper: one refresh run can reach a sign-in from `soft_refresh` and then from `login`.

**HTTP first, Chrome as the fallback:**

| Where | Before | Now |
|---|---|---|
| `renew_login` (scheduled, before the 24-hour limit) | Chrome | HTTP. If refused: stop, keep the session, no Chrome attempt. Otherwise Chrome. |
| `login` (new connections, Validate, refresh's password fallback) | Chrome cookie restore, then Chrome sign-in | HTTP. On any failure, refusal included: Chrome as before. Only Chrome marks a login failed. |
| `soft_refresh` (scheduled refresh **and the pre-order check**) | API refresh, then Chrome cookie restore | API refresh, then **HTTP sign-in**, then Chrome cookie restore |

## Ordering-safety review

- **`soft_refresh` is what the pre-order check calls** (`PreOrderValidationService#establish_scraper_connection!`). On false it stops the order with "Session may have expired". The new HTTP step only runs after the API refresh failed, and only adds a way to return true. When it works, the order proceeds with fresh tokens, the same scraper's `api_client` already holding them. When it fails, the old Chrome step runs as before. **No order is stopped that wasn't before. Some that would have been stopped (a Performance login past its 24 hours) now go through.** Specs cover all three paths.
- **Unchanged:** cart, checkout, submit, price verification and the other pre-order checks. They call `ensure_session!`, which is untouched.
- **A sign-in during a placement** happens under the existing per-account lock (`Orders::SupplierAccountLock`), like any session work there. It writes `session_data` and `mark_active!`, as the Chrome path already did.
- **No new way to mark a login failed.** `sign_in` and `http_sign_in` write no failure state, and Chrome stays the only thing that marks a Performance login failed.

**Account lockout.** With a wrong stored password, one refresh run now sends it:
- once over HTTP (`soft_refresh`),
- the HTTP refusal is remembered, so `login` skips HTTP,
- then once in the Chrome login,

so 2 attempts, up from 1, every 6–8 hours. That's far below B2C's lockout threshold. `renew_login` never tries Chrome after a refusal.

## Chrome after this

About zero for Performance in normal running: the daily renewal, new connections and dead-session recovery all sign in over HTTP. Chrome only runs when an HTTP sign-in fails (the page changed, a robot check added, a network error), and the logs say so: "Sign-in without a browser did not complete: …".

## Tests

`spec/services/scrapers/performance_api_spec.rb`, `#sign_in`:
- signs in and loads a 24-hour login
- submits email and password with the page's CSRF token and cookies
- the PKCE verifier matches the challenge, and the SPA `Origin` is sent
- saved tokens restore with no further requests
- existing MSAL entries are updated in place, keeping account data and cookies
- a refused password returns `:rejected` and saves nothing
- `:failed` for: no form, a credentials-step error, no code, a refused token step, a network error, no stored password
- the log never contains a secret

`spec/services/scrapers/performance_scraper_spec.rb`:
- `login`: HTTP with no browser; Chrome on failure; Chrome even on refusal
- `renew_login`: HTTP with no browser; no Chrome on refusal; Chrome on failure
- `soft_refresh`: the API alone; HTTP before any browser; Chrome when both fail
- `http_sign_in` marks the login active, never raises, and doesn't resend a refused password
- The Oct 20 `soft_refresh` browser-fallback specs now stub the HTTP step as failing, which keeps what they test.

Full suite with all three Performance changes on this branch: **2,205 examples, 0 failures**.

## What we did NOT do

- **No HTTP sign-in from page-view jobs.** The delivery-days job still only resumes a session.
- **No credential handling outside the existing path.** `sign_in` reads `credential.username` and `credential.password` as the Chrome sign-in does, and sends them only to Performance's B2C host.

## After deploy, check

- In the worker logs: "Signed in without a browser (login lasts 86400s)" from `RefreshSessionJob`, and no `[Scraper] Starting browser` for Performance.
- If a Performance sign-in says "did not complete", Chrome took over. Read the reason: the page changed, or a robot check appeared.
