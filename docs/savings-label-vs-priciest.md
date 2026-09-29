# Savings relabelled "Saved vs. Priciest"

**Date:** 2026-09-29 · **Decision:** Carmin · **Status:** built, not yet deployed · **Numbers:** unchanged (labels only)

## Why

Reports showed Performance Foodservice at **$365.40 spent / $555.55 saved**. That looked like a bug, but it isn't one. Order 335's high-gluten flour line cost $167.45 for 5 × 50 lb Gold Medal **All Trumps**. US Foods charges **$82.57** a case for the same flour (confirmed live, read-only), so the priciest option was $412.85 and the line counts $245.40 saved. The per-unit maths is right: $0.0419/oz paid against $0.1032/oz, × 800 oz × 5.

The Aug 31 2026 decision measures savings against the **most expensive comparable supplier**, the "careless-order view": what an order would have cost if the chef had picked the priciest option. Carmin kept that model, because chefs really do order the familiar or smaller-pack item without looking. A line can therefore "save" more than was spent on it. Calling that plain "Savings" read as an error, so the label now says what it's measured against.

## Changes

"Savings" became **"Saved vs. Priciest"** wherever the stored savings figure is shown:
- Reports: summary card, by-restaurant / supplier / member / location tables, the savings page headline, product table and section, and the mobile summary.
- Dashboards (owner and manager, desktop and mobile).
- Orders: the list, the review, mobile order detail and the mobile list.
- The order-placed email.

Unchanged:
- "Product Savings" and "Missed Savings" (page names; those pages explain their basis).
- "Potential Savings" on the order-list price comparison (a different, pre-order figure).

Spec: `reports_location_scope_spec.rb` checks that Reports shows "Saved vs. Priciest".

## Open (not decided)

- **Pack-format mismatch:** order 335's capers ($92.04) were benchmarked against Sysco's 12 × 3.5 oz retail jars against a 32 oz jar. The pack gate compares total case ounces, not unit size.
- **Stored vs. today's figures:** savings are snapshotted at order time. Order 335 recomputes to $348.09 today against $555.55 stored, because peer prices have moved since.

## Also in this change: Top Products columns cut off

On `/reports/supplier/:id` (and the member and location reports, which share `_top_products_table`), long supplier names pushed Qty / Total Spent / Orders past the right edge of the half-width card, and the card's `overflow-hidden` clipped them.

The name cell had `max-w-xs truncate`. `truncate` keeps the text on one line, but browsers ignore `max-width` on table cells, so the cell grew to the full name. The name cell now uses `w-full max-w-0` with the truncation on an inner `<div>` (title shows the full name), the number cells are `whitespace-nowrap`, and the table sits in an `overflow-x-auto` wrapper as a backstop. There's a spec in `reports_accuracy_spec.rb`.
