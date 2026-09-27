# Performance delivery dates in the builder and review (Sep 27 2026)

## Why
Proving the new delivery-date call on the leftover order #334 draft, Performance refused Friday Oct 2: **"Delivery Day of Friday is not allowed."** EnPlace had let the chef pick it. Carmin: "if they don't deliver friday I kind of need to know that."

A read-only probe of the endpoint the CustomerFirst site uses for its own date picker (`Customer/V1/GetCustomerDeliveryDates?customerId=…&ignoreCutOff=false`, from the site's code) showed:
- **D'oro (cred 131):** 26 dates, **Tuesdays and Fridays** (Sep 29, Oct 2, Oct 6 …).
- **alfios (cred 127):** `IsSuccess: false`, "You are not currently set up for deliveries. Please contact your Sales Representative." Carmin: Performance is probably D'oro only for now.

## What changed
- `Supplier#delivery_dates_source` returns `:api` for `performance` as well as `sysco`, so the existing supplier-dates machinery (builder badges, review hints, the 4-hour background refresh) covers Performance.
- `PerformanceApi#customer_delivery_dates` returns `{ dates: ["YYYY-MM-DD", …], error: nil }`, or `{ dates: [], error: <PFG's message> }`. `PerformanceScraper#delivery_dates_result` wraps it.
- `FetchSyscoDeliveryDatesJob` (name kept) runs for any supplier with a dates API. For Performance it stores both dates and PFG's reason (new `supplier_credentials.delivery_dates_error`, migration `20260927200000`); a transport failure leaves previous values alone. The Sysco path is unchanged.
- **Builder:** the supplier's date badge shows "✓ Delivers Tue Oct 6" or "⚠ No delivery — next: …" from Performance's own dates. When Performance won't deliver to the account, it shows a red "⚠ Not set up for deliveries" as soon as a Performance item is in the cart, with PFG's message on hover.
- **Review page:** the same message under the order's date.
- Order placement also sets the date on the PFG draft (`fix-performance-submit.md`), so a disallowed date fails loudly with PFG's message before any submit.

## Tests
`spec/jobs/fetch_sysco_delivery_dates_job_spec.rb` (3), `performance_api_spec` (+2), `supplier_spec` (updated), `order_builder_bar_spec` (+1). Full suite: 1,528.

## Follow-up: fetch delivery days on connect (Sep 27 2026)
Carmin: "why doesn't it happen automatically?" The builder refreshed missing or stale dates in the background, but the page doing the refresh showed the old (empty) value, so a newly connected supplier's days appeared only on the **second** builder visit. `ValidateCredentialsJob` now queues `FetchSyscoDeliveryDatesJob` (forced) as soon as a Sysco or Performance login validates. Spec: `spec/jobs/validate_credentials_job_delivery_dates_spec.rb`.
