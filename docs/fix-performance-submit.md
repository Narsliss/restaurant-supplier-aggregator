# Fix: Performance order submit, delivery date, cart clearing (Sep 27 2026)

## What happened
The first real Performance order through EnPlace (#334: alfios, 5 lines, 20 cases, $561.53) failed at submit. Performance answered `IsSuccess: false, "Order not found."`. Nothing was placed. Session, pre-order check, price verification, cart building and cart reconciliation all worked: the PFG draft held exactly 5 lines, 20 cases and $561.53.

A read of that draft showed a second bug: its delivery date was **Mon Sep 28** (PFG's default), not the chef's **Fri Oct 2**. EnPlace never sent a delivery date to PFG. Had submit worked, the order would have shipped on the wrong day.

Carmin did not want test orders ("I much prefer not having to make 3 orders to be cancelled"), so the fix was derived without submitting anything.

## How the right shapes were found
From CustomerFirst's own public site code (`www.customerfirstsolutions.com/static/js/main.b1187684.js`). Its API base class is `post(url, data, mode = "body")`; in `"queryParams"` mode it sends `axios.post(url, {}, { params: data })`, i.e. an empty `{}` body with the fields as URL query parameters. The `OrderEntryHeader` service:

| Call | Site sends | We sent |
|---|---|---|
| `SubmitOrderEntryHeader` | `{ OrderEntryHeaderId, TimeZone }` as **query params**, body `{}` (TimeZone = `Intl…resolvedOptions().timeZone`) | JSON body `{ OrderEntryHeaderId, CustomerId }`, hence "Order not found." |
| Submit success | `IsSuccess` **and** `ResultObject.AcceptOrder`; otherwise "Your order could not be submitted" | `IsSuccess` only |
| `UpdateOrderEntryHeaderDeliveryDate` | JSON body `{ OrderEntryHeaderId, DeliveryDate }` | never called |
| `DeleteOrderEntryHeader` | `{ OrderEntryHeaderId }` as query params | never called; `clear_cart` was a no-op because PFG has no line-list read |

## Changes
- `PerformanceApi#submit_order`: query params (`OrderEntryHeaderId`, `TimeZone` = `America/New_York` from the app zone), empty body. A WebMock test pins the exact wire format.
- `PerformanceApi#update_delivery_date` (`"YYYY-MM-DDT00:00:00"`, PFG's own format), `#delete_order_entry_header`, `#forget_active_order!`.
- `PerformanceScraper#add_to_cart` sets the chef's delivery date on the draft and fails loudly if PFG refuses it. `verify_cart_matches!` re-reads the date and fails closed on a mismatch.
- `PerformanceScraper#clear_cart` deletes the open unsubmitted draft, the site's own way to discard one, so a stale draft can't block or leak into the next order. The next add creates a fresh draft. If PFG refuses the delete, the draft stays and verify fails the order closed.
- `PerformanceScraper#checkout` counts an order as placed only when `IsSuccess` **and** `AcceptOrder == true`.

## Tests
`performance_api_spec` and `performance_ordering_spec` (+8 examples). 11 of them fail on the previous code.

## Still unproven live
The submit itself can only be proven by a real order; its shape is copied from the site's code and pinned on the wire. The delivery-date and delete calls can be proven on the leftover #334 draft without submitting.

## Noted, not changed
`PreOrderValidationService#validate_order_minimum!` logs `undefined method [] for nil` when a scraper's `get_order_minimum` returns nil (PFG with no minimum). It is rescued and harmless, but noisy.
