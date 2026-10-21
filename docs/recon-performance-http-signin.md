# Recon: can Performance sign in without Chrome?

**Date:** 2026-10-21
**Status:** both steps done, and **it works.** A full sign-in over plain HTTP succeeded on a real login, and the API accepted the token. Carmin said go, and it's built: docs/fix-performance-signin-without-chrome.md.

## Result of step 2 (run by Carmin, Oct 21 2:44 PM ET, credential 128 = D'oro, Alfio's)

```
1. sign-in page: HTTP 200, csrf found, transId found
2. credentials: HTTP 200, B2C status "200"
3. confirm: HTTP 302, redirect to https://www.customerfirstsolutions.com/, code received
4. tokens: HTTP 200, access yes, refresh yes, expires_in 3600, refresh_token_expires_in 86400
5. API check (GetCurrentUserSite): HTTP 200 (accepted)
Nothing was saved.
```

- **No browser needed.** The B2C custom policy completes with five plain HTTP requests. No hidden challenge, and nothing computed by JavaScript.
- **`refresh_token_expires_in: 86400` = 24 hours** on a fresh sign-in. This confirms the 24-hour login limit from B2C itself.
- **Access tokens last 1 hour** (`expires_in: 3600`).

## Why

Performance logins end 24 hours after a real sign-in; refreshing can't extend them (docs/fix-performance-dates-session-expired.md). So every Performance login needs a real sign-in about once a day.

Today that sign-in is Chrome (`PerformanceScraper#perform_login_steps`): ~250 MB per launch, ~2,250 launches a day at 10,000 users. A sign-in over plain HTTP would cost a few requests.

## Step 1: what the sign-in page shows (anonymous, read-only)

Done Oct 21 with no credentials and nothing submitted. Scripts: scratchpad `pfg_recon/spa_config.py`, `pfg_recon/signin_page.py`.

**The app's own settings** (public script `main.bf3c4686.js`):

| Setting | Value |
|---|---|
| Authority | `https://pfgcustomerfirst.b2clogin.com/pfgcustomerfirst.onmicrosoft.com/B2C_1A_signup_signin/` |
| Client ID | `c68e7fae-80a1-42db-bd89-3fb37d1224a2` (same as `PerformanceApi::CLIENT_ID`) |
| Redirect URI | `https://www.customerfirstsolutions.com` |
| API scope | `https://pfgcustomerfirst.onmicrosoft.com/api/customer-first-site-api` |
| Idle timeout | `REACT_APP_CONFIG_SESSION_TIMEOUT` 1200 (20 min) |

**The sign-in page** (`/oauth2/v2.0/authorize` with PKCE, as the app calls it):
- It's the standard Azure AD B2C self-asserted page, `api: "CombinedSigninAndSignup"`. It has the `SETTINGS` block a form post needs: `csrf` and `transId`, plus cookies `x-ms-cpim-csrf`, `x-ms-cpim-trans`, `x-ms-cpim-cache`.
- The fields are `signInName` and `password` (`operatingMode: "Username"`), the button is `next`, and the form is `localAccountForm`.
- **No robot check.** There's no reCAPTCHA, hCaptcha, Arkose or Turnstile on the page, and no external scripts. The app does carry a reCAPTCHA site key, but it's for a form inside the app (an explicitly rendered `grecaptcha` widget), not for sign-in.
- **`enableRememberMe: "false"`.** Performance has switched off "Keep me signed in". That matches the 24-hour cap, and it means `check_remember_me` in our Chrome sign-in has nothing to tick.
- The page look comes from a remote template (`sazzcusfstwebloginpeus01.azureedge.net/unified.html`). That's cosmetic for an HTTP client.

**Conclusion:** nothing on the page needs a browser. The standard headless B2C sequence should work:
1. GET `/authorize` (PKCE) → read `csrf` and `transId`, and keep the cookies.
2. POST `/SelfAsserted?tx=…&p=B2C_1A_signup_signin` with `X-CSRF-TOKEN` and the form `request_type=RESPONSE&signInName=…&password=…` → expect `{"status":"200"}`.
3. GET `/api/CombinedSigninAndSignup/confirmed?rememberMe=false&csrf_token=…&tx=…&p=…` → a redirect to the redirect URI carrying `code=…`.
4. POST the token endpoint (`PerformanceApi::TOKEN_ENDPOINT`): `grant_type=authorization_code`, `code`, `code_verifier`, `redirect_uri`, `client_id`, `scope`, with `Origin: https://www.customerfirstsolutions.com`. The app is a single-page-app client, so redemption may require that origin.
5. Check the new access token with one read-only API call, `Site/GetCurrentUserSite`.

## Step 2: one real sign-in (not run)

Steps 2–4 submit a real email and password, and Claude doesn't enter passwords to sign in. So Carmin runs a one-time test himself, on one Performance login he chooses, ideally his own.

**What the test does:**
- runs inside the production container, where the login decrypts
- reports each step's HTTP status, whether a code and tokens came back, `expires_in`, `refresh_token_expires_in`, and whether the API accepts the new token

**What it doesn't do:**
- print or save any password, token or cookie
- write to our database (booting `rails runner` re-saves the seeded suppliers as every boot does)

Its side effect is one extra sign-in on that Performance account, the same as our daily Chrome sign-in.

**Files** (scratchpad `pfg_recon/`):
- `http_signin_test.rb`: the test. `CRED_ID = 128`, the Performance login whose refresh failed on Oct 21. It prints that login's restaurant before doing anything.
- `run_http_signin_test.sh`: runs it once over `railway ssh -s pretty-friendship`, then deletes the file from the container. Output goes to `http_signin_test_output.txt`.

**Go/no-go after step 2:**
- **Go:** if all five steps pass, build an HTTP sign-in for the scheduled renewal (`PerformanceScraper#renew_login`), with Chrome kept as the fallback. It would save tokens in the MSAL-cache shape `PerformanceApi#restore_session` already reads, and get the ordering-safety review, specs and a record.
- **No-go:** if B2C demands something only a browser can give (a hidden challenge, JS-computed values), keep the daily Chrome renewal.

## Build plan (awaiting Carmin's go)

Same branch as the 24-hour fix (`perf-dates-auth`).

1. **`PerformanceApi#sign_in`** runs the five requests above with the login's stored email and password. It returns true and loads the new tokens on success.
   - It writes the tokens into `session_data` the way `persist_tokens!` does, updating the existing MSAL entries so the browser fallback still finds its account data. With no entries yet, it creates minimal ones in the shape `restore_session` reads.
   - It never logs or raises with a password, token, cookie or code.
2. **`PerformanceScraper#renew_login`**, the scheduled pre-limit renewal, tries the HTTP sign-in first and Chrome only if that fails. In normal running that means no Chrome at all.
3. **`PerformanceScraper#login`** (new connections, Validate, and the refresh's password fallback) also tries HTTP first.
   - If B2C rejects the email or password (step 2 answers with a non-200 status), that's final: no Chrome retry, the login is marked failed with B2C's message, as today.
   - Any other HTTP failure falls back to the Chrome login.
4. **`PerformanceScraper#soft_refresh`** is the ordering path and needs the ordering-safety review. Today: API refresh, then Chrome cookie restore, otherwise the pre-order check stops the order. Proposed: API refresh, then **HTTP sign-in**, then Chrome cookie restore. That adds one more way to succeed before an order would be stopped, so it's never worse.
5. **Specs** with WebMock for the full flow:
   - success
   - each failure mode: no sign-in form, credentials rejected, no code, token error
   - HTTP-first ordering in `login`, `renew_login` and `soft_refresh`
   - nothing secret appears in the logs
6. A record, the full suite, then ask before commit or push.

**Chrome after this:** about zero for Performance in normal running. Chrome only runs when an HTTP sign-in fails.

## Risks to weigh before building

- **Page changes:** if Performance changes its sign-in page, the HTTP sign-in breaks. The Chrome fallback covers that, and the logs would show it.
- **The same password goes over the same channel:** the app already sends it to this endpoint, through Chrome. Nothing new is exposed.
- **Microsoft could add bot protection later.** Again, Chrome fallback.
