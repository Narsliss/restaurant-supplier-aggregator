# Out-of-stock items can't go in the cart; the price check always reads stock

**Date:** 2026-10-19 (evening) · **Branch:** `claude/charming-grothendieck-c1c08e` · **Status:** built and tested, NOT committed, NOT pushed · **Plan:** `docs/plan-out-of-stock-all-suppliers.md`

## What Carmin asked for

His description of the finished system (Oct 19):
- A morning run reads stock for all products, once per supplier.
- Items it finds out can't be put in a cart.
- Anything that sells out between the morning and order time is flagged at the price check, and the chef is told to take it out. Otherwise the order fails.

Checking that against the code showed two gaps, and Carmin asked for both to be closed before the push.

1. **Gap 1:** an item marked out still showed as a dimmed "Out of stock" cell in the desktop order builder, and a chef could still tap it and add it.
2. **Gap 2:** the price check skipped its live read, stock included, whenever every item's price had been refreshed in the last hour. The 8 AM guide sync refreshes guide items, so an all-guide order checked before about 9 AM relied on the 8 AM reading.

## What changed

### Gap 1: order builder

- **One rule, shared with the review page:** `Supplier#out_of_stock_warns_only?` (US Foods, Carmin's D1: "warn on 0 on hand; block only discontinued"). The helper `builder_cell_orderable?(supplier, item)` says a cell is not orderable when the item is discontinued, or out at a supplier where out blocks.
- **Desktop builder** (row, card and small-screen card layouts):
  - A cell that isn't orderable is dimmed, can't be picked, and doesn't take a quantity.
  - The default selection moves to an orderable supplier.
  - A line already on that cell (from a saved working order) can still come down or off, never up.
- **Phone builder:**
  - It already disabled out cells for every supplier. It now uses the same rule, so US Foods cells stay orderable, per D1.
  - "+" is disabled on a line already in the cart for a supplier where out blocks.
  - The "In this order" list says "Out of stock at <supplier>", plus "remove it or pick another supplier" where it can't be ordered.
- **Create Cart is unchanged.** Dropping a selected line there would be silent. The review page stays the hard gate: Place is off for an out item at every supplier except US Foods, which warns.

### Gap 2: price check

`PriceVerificationService#verify!` no longer takes the fresh-price shortcut for a supplier whose price check reads live stock (`reports_live_stock?`: all six scraped suppliers). That read is the last stock check before Place. Email suppliers keep the shortcut.

## Ordering impact

- No cart, add-to-cart, submit or checkout code changed.
- Chefs can no longer add an out item from the builder, except at US Foods, which warns per D1.
- Every price check for the six suppliers is now a live read. It takes as long as a live read: an extra read per order guide at Chef's Warehouse, and one call per 20 items at Sysco.

## What did not work, or was decided along the way

- **US Foods in the builder:** Carmin's words were "make out-of-stock cells not addable". D1 (US Foods out only warns) applies here too, so US Foods stays addable with the "Out of stock" label on both builders. This was said before building. Blocking US Foods as well is a one-line change in `Supplier#out_of_stock_warns_only?`.
- **Changed existing phone behavior:** the phone builder blocked US Foods out cells before this change; it now follows D1.

## Checked in the browser

On a private copy of the dev database, migrated to this branch (dropped afterwards). One matched product (a dishwasher sanitizer) was marked out at Chef's Warehouse and at US Foods.

- **Desktop:** clicking the Chef's Warehouse cell changed nothing, and the selection stayed on US Foods. "+" added one at US Foods. A line already on Chef's Warehouse wouldn't go from 2 to 3, but went down to 1.
- **Phone:** the Chef's Warehouse "+" was disabled and didn't raise the line. "−" removed it, and the cell then couldn't be tapped. The US Foods line in the order list read "Out of stock at US Foods".

## Specs

- New: `spec/requests/order_builder_out_of_stock_spec.rb` (desktop and phone cells, the shared supplier rule).
- New example in `spec/services/orders/price_verification_service_spec.rb`: fresh prices still get a live read when it is the stock check.
- All four new examples fail on the previous commit (`603b16d`). Full suite: 1,983 examples, 0 failures.

## Still open

- **Review page:** it re-runs the price check only when the last one is over an hour old. A cart left open for 50 minutes places on a 50-minute-old reading. The supplier's refusal at checkout still stops the order and names the item.
- **Chef's Warehouse off-guide items** get no stock reading at the price check: CW has no stock lookup by item number that we know of. They read "unknown" and aren't blocked; CW's own refusal at checkout stops the order.
- **Sysco and US Foods morning coverage** is about half and three quarters of the catalog, though nearly all items on lists are covered.
