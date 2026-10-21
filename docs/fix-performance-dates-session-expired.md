# Fix: Performance logins die at the 24-hour limit (and the delivery-days alert)

**Date:** 2026-10-21
**Branch:** `perf-dates-auth`, from `main` at `fe228e9`. Not committed or pushed.
**Trigger:** Sentry, Oct 21: `Scrapers::PerformanceApi::AuthError` in `FetchSyscoDeliveryDatesJob`, "Performance API session expired — re-login required".

**Two changes:**
1. **Sign in again before the limit.** The scheduled session refresh now signs Performance in again with the stored password once the login has less than 9 hours left, while the current session still works. That's the real fix; see "Change 2".
2. **Quiet the alert.** The delivery-days job treats an expired Performance session like Sysco's: one quiet log, stored dates kept. See "The change".

## What happened

`FetchSyscoDeliveryDatesJob` refreshes Sysco/Performance delivery days. It's queued from order-builder and review page views when the stored days are more than 4 hours old (`DeliveryDatesRefresher`).

For Performance:
- It calls `PerformanceScraper#delivery_dates_result` → `PerformanceApi#ensure_session!`. That resumes the saved session (and refreshes its token against B2C), or raises `PerformanceApi::AuthError`.
- The job only rescued `Scrapers::BaseScraper::AuthenticationError`. `PerformanceApi::AuthError` (`< ApiError < StandardError`) fell through to `retry_on StandardError, attempts: 2`, so it retried once and then failed into Sentry.

**Impact:** none on orders. The stored delivery days were left as they were, as on any failure.

## Why the token refresh failed (worker logs, Oct 21)

**The refusal.** B2C refused the refresh with `HTTP 400 invalid_grant`, "AADB2C90080: The provided grant has expired". The stored refresh token for credential 128 was issued at `1792591202` (10:00:02 AM ET) and expired at `1792591208`, **6 seconds later**.

**Every Performance token refresh in the last 24 h (`refresh token lasts`):**

| ET | Job | Lifetime | Ends at (ET) |
|---|---|---|---|
| Oct 20 10 PM | RefreshSessionJob ×2 | 57,604 s | 2 PM |
| 2 AM | RefreshSessionJob ×2 | 28,805 s | 10 AM |
| 6 AM | RefreshSessionJob ×2 | 28,805 s | 2 PM |
| 6:25 AM | ImportSupplierProductsJob | 27,296 s | 2 PM |
| 8 AM | ImportSupplierListsJob | 7,205 s | 10 AM |
| **10 AM** | RefreshSessionJob ×2 | **6 s / 5 s** | 10 AM |
| **2 PM** | RefreshSessionJob ×2 | **5 s / 5 s** | 2 PM |

**What the table shows:**
- **A hard 24-hour limit.** Two pairs of Performance logins each have a fixed end time, one 10 AM and one 2 PM. Every refresh hands back a token that runs only to that same end. It looks like B2C caps a login at 24 hours from the last real (browser/password) sign-in, and refreshing can't extend it. At the end, B2C still answers "OK" but with a refresh token that lasts 5–6 seconds.
- **Our bug, since db72f81 (Oct 20, API-first refresh).** `PerformanceScraper#api_soft_refresh` treats that answer as success. It saves the dead token (`persist_tokens!`) and calls `mark_active!`, which sets `last_login_at` to now. `RefreshSessionJob` only revisits a login whose `last_login_at` is more than 6 hours old, so the real re-login (browser, then password) waits 6–8 hours.
  - Before Oct 20, the refresh was browser-only: it failed at the 24-hour wall, and `SessionManager` went straight to a password login.
- **The dead windows today:** the 10 AM pair until the 6 PM ET refresh run, and the 2 PM pair until the 10 PM ET run. In those windows every Performance API call on those logins fails: list syncs (1 `ImportSupplierListsJob` failure today), imports, delivery days (4 failures).
  - An order through those logins goes through pre-order validation. `soft_refresh` there tries the API and then the browser. If the browser can't revive the session either, the order stops with "Could not establish connection to Performance Foodservice". It is not placed, and the stop is shown clearly.
  - No Performance order ran on the worker since the Oct 20 evening deploy, so nothing was hit today.
- **This repeats daily** for every Performance login.

The real fix, signing in again before the limit, is "Change 2" below.

## The change

The job now rescues `Scrapers::PerformanceApi::AuthError` alongside `Scrapers::BaseScraper::AuthenticationError`, the same way: one warning log, stored dates kept, no retry, no alert.

`delivery_dates_fetched_at` stays stale on purpose, so the next page view asks again. Once the session is alive, the dates refresh as usual.

One file changed (`app/jobs/fetch_sysco_delivery_dates_job.rb`), plus 3 specs in `spec/jobs/fetch_sysco_delivery_dates_job_spec.rb`:
- An expired session keeps the dates, finishes without a retry, and leaves `delivery_dates_fetched_at` stale.
- It calls neither `login` nor `soft_refresh`, and the login stays `active`.
- An unreachable Performance (`ApiError`, not an auth problem) still retries, as before.

The first spec failed on `fe228e9` (a retry was queued) and passes with the change. Full suite: 2,166 examples, 0 failures.

## Change 2: sign in again before the 24-hour limit

Carmin, Oct 21: "performance is not 2fa right, why can't we do something similar to our password only suppliers?" We already do. When a refresh fails, `SessionManager#refresh_session` falls through to a full password login, just as for Chef's Warehouse and What Chefs Want. The refresh just never failed: at the limit it "succeeded" with a 6-second token. So:

- **`PerformanceApi#refresh_token_expires_at`:** each refresh records when the login ends, from B2C's `refresh_token_expires_in`. It's nil when no refresh happened or B2C didn't say.
- **`PerformanceScraper#login_ending_soon?`:** true when that end is less than `RENEW_LOGIN_WITHIN` (9 hours) away. Nine hours is longer than the widest gap between two scheduled refreshes of one login: 6 hours (`needs_refresh?`), then the 2-hourly cron. So the login is renewed before it can die between refreshes. An unknown end counts as false.
- **`PerformanceScraper#renew_login`:** a fresh email + password sign-in in a new, empty browser profile, so the sign-in form always shows. It saves the new session and marks the login active.
  - Unlike `#login`, it **never marks the login failed**. It runs while the current session still works, so if sign-in fails or raises, the current session is kept, it returns false, and the next scheduled refresh tries again.
- **`SessionManager#refresh_session`:** after a successful soft refresh, it calls `renew_login` when the scraper reports `login_ending_soon?`. Only Performance implements that, so every other supplier behaves exactly as before. A failed renewal still reports the refresh as working.

**Cost:** about one Chrome sign-in per Performance login every ~16 hours, at the scheduled refresh. That's still less Chrome than before Oct 20, when every refresh used it. Page-view jobs never sign in.

**With Oct 21's logins:**
- The 10 AM pair would have been renewed at the 2 AM ET refresh: 8 h left, which is under 9 h.
- The 2 PM pair would have been renewed at the 6 AM ET refresh: 8 h left.
- Neither would have gone dark.

**After the deploy:** the logins that are dead today recover at their next eligible scheduled refresh, as today (the API refresh fails, then browser, then password). From then on they're renewed ahead of the limit.

Specs:
- `spec/services/scrapers/performance_api_spec.rb`: the end is recorded, unknown when not reported, and unknown when no refresh happened.
- `spec/services/scrapers/performance_scraper_spec.rb`:
  - `login_ending_soon?`: 5 s and 8 h left are true, 16 h is false, unknown is false
  - `soft_refresh` near the end still returns true and opens no browser (what ordering calls)
  - `renew_login`: it saves on success, and keeps the login active when sign-in doesn't complete or raises
- `spec/services/authentication/session_manager_refresh_spec.rb`:
  - plenty left means no new sign-in
  - ending soon signs in again
  - a failed renewal still counts as a working refresh, and the login stays active
  - other suppliers are unchanged
  - a failed refresh still goes to the full password login

Full suite: 2,181 examples, 0 failures.

## Ordering-safety review (both changes)

- **Unchanged:** `OrderPlacementService`, cart/checkout, price verification and `PreOrderValidationService`.
- **`soft_refresh`'s answer is unchanged.** Ordering's pre-order check (`PreOrderValidationService#establish_scraper_connection!`), price verification and the exception checker call it. Near the limit it still says the session works and opens no browser; a spec covers this.
- **Signing in again happens only in the background** scheduled refresh (`RefreshSessionJob`, the only caller of `SessionManager#refresh_session`).
- **What changes for ordering:** Performance logins should no longer go dark for 6–8 hours a day. A Performance order in that window could otherwise be stopped at the pre-order check with "Could not establish connection".
- **No new way to block an order:** `renew_login` never marks a login failed. The only status write is `mark_active!` on a successful sign-in, which a normal login also does.
- **Delivery days:** as in the first change, an auth failure leaves stored days untouched, before and after.

## What we did NOT do, and why

**The job does not log Performance back in.** The proposal said it would; reading the code changed that.
- Every Performance operation (catalog, lists, prices, cart, checkout) resumes the saved session the same way and never logs in itself.
- Logging in is the job of the 2-hourly `RefreshSessionJob` → `SessionManager#refresh_session`: API refresh, then the browser, then a full password login.
- A login here would launch Chrome from a job that page views trigger. On a failed login, `delivery_dates_fetched_at` isn't updated, so every later builder or review view would launch Chrome again. Worker memory is already the cost problem (Oct 21 post-deploy check).

## Ordering-safety review

- **No ordering code changed:** `OrderPlacementService`, the scrapers' cart/checkout, price verification and the pre-order checks are untouched.
- **Stored delivery days do feed submission:** `OrdersController#undeliverable_date_message` can refuse a Sysco/Performance order whose date isn't a stored delivery day. This change doesn't alter when the stored days change. On an auth failure they were left alone before and are left alone now. The only differences are no second attempt 30 s later and no Sentry alert.
- **Never placed or blocked an order differently:** the job's success path is untouched.

## Open items (not done here)

- **After the deploy, watch one cycle.** In the worker logs, look for "[SessionManager] … login ends soon, signing in again" and "[Performance] Signed in again before the 24-hour login limit" at the next refreshes. "refresh token lasts" should never show seconds again.
  - If sign-in keeps failing ("Signing in again failed, keeping the current session"), the login will still die at the limit and recover the old way.
- **Is the window really 24 hours?** Inferred from the Oct 20–21 lifetimes, which all count down to two fixed end times. The fix doesn't depend on it: it acts on the end time B2C reports.
- **Rotated tokens aren't saved.** `ensure_session!` refreshes tokens but doesn't save the rotated refresh token (`persist_tokens!`), unlike `api_soft_refresh`. It's harmless while B2C keeps old refresh tokens valid. Worth knowing if the refresh-token lifetimes above turn out to be real.
- **Sysco's path still opens a browser from page views.** Sysco's branch of this job calls `ensure_api_session!`, which opens a browser when its JWT has expired (tokens last about 7 days). That was existing behaviour and is not changed here.
