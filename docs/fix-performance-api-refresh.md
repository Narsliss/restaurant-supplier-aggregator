# Fix: refresh Performance logins without Chrome

**Date:** 2026-10-20 · **Status:** built and tested (full suite 2081/0), not committed · **Order placement:** yes, indirectly. Pre-order validation calls this refresh before every Performance order. Read "Ordering impact" below.

## What changed

`PerformanceScraper#soft_refresh` used to open Chrome on every call. It ran from three places:
- `RefreshAllSessionsJob`: every 2 hours, and each login needs a refresh after 6 hours, so about 4 times a day per login.
- `PreOrderValidationService#establish_scraper_connection!`: before every Performance order.
- `SessionManager#validate_credentials`: when a login is checked.

Now:

1. **API first** (`api_soft_refresh`):
   - `PerformanceApi#restore_session` loads the MSAL tokens and refreshes them against B2C if they've expired.
   - One read-only call (`Site/GetCurrentUserSite`) proves the token works. The middleware answers 203 when it doesn't, and `call` raises on that.
   - `PerformanceApi#persist_tokens!` writes the new access and refresh tokens back into the stored MSAL cache.
   - The login is marked active.
2. **Browser fallback** (`browser_soft_refresh`): if any API step fails, the old Chrome refresh runs, unchanged.

`refresh_access_token` now also logs B2C's `refresh_token_expires_in`. That's the open "Session TTL" item in `prd-performance-integration.md`: the next production runs will show how long a Performance login lasts without a browser.

## Why

- **Cost and scale.** Chrome is the heaviest per-login work after the Sysco 8 AM catalog import (Railway analysis, Oct 20). At 10,000 users that's about 9,000 Chrome launches a day for Performance alone.
- **The API path already existed.** `PerformanceApi` has refreshed tokens without a browser since September, and the 6 AM import, the guide sync, the cart and the submit all depend on it.
- **Speed.** A Performance order's pre-order check no longer waits for Chrome to start.

## Ordering impact

- **Pre-order validation does not retry with a login.** If `soft_refresh` returns false, the order is blocked with "Session may have expired". So an API-only refresh would block any order where the API fails but the browser would have worked. That's why the browser stays as the fallback *inside* `soft_refresh`. Every caller gets the same answer as before or better; it's never worse.
- **Saved tokens.** The newest tokens are now written to `session_data` whenever the API refresh succeeds. The cart and submit code (`PerformanceApi#ensure_session!`) read the same entries, so they start from fresher tokens. A failed save is logged and never raises.
- **Unchanged:** the submit code, the cart code, and the full browser login.

## What did NOT work / was rejected

- **API only, no browser.** Rejected because of the pre-order behavior above.
- **Saving tokens on every API refresh (imports, cart, submit).** Rejected for now: it would add database writes on the order-submit path. Saving only in the soft refresh keeps that path unchanged.

## Open items

- **How long a Performance refresh token lives.** Unknown; read `refresh_token_expires_in` from the production logs. If B2C caps browser-app refresh tokens at 24 hours, the API refresh starts failing a day after the last browser session. The browser fallback then runs about once a day per login instead of about 4 times. That's still about 75% fewer Chrome launches.
- **Not yet run against a live Performance login.** The specs stub B2C and the middleware.

## Tests

- `spec/services/scrapers/performance_scraper_spec.rb`, `#soft_refresh`:
  - API success saves tokens and never opens a browser.
  - No usable token falls back to the browser.
  - A rejected (203) token falls back to the browser and saves nothing.
  - The result is false only when both fail.
- `spec/services/scrapers/performance_api_spec.rb`, `#persist_tokens!`:
  - Writes the access token, its expiry and the rotated refresh token into the MSAL entries in both storages, and keeps cookies and other keys.
  - The next restore uses the saved token without calling B2C again.
  - Saves nothing when no refresh happened.
  - Returns false on an unreadable session without changing it.
