# Fix: dark-mode gaps on the ordering screens

Status: **built Oct 21 2026, not committed.** Found by the Safari audit (`docs/safari-audit-2026-10-21.md`). These happen in every browser, not just Safari.

**Ordering impact: none.** Only colours change. No markup, no JS behaviour, no form fields. The disabled state is still the `disabled` attribute, set by `order_builder_controller.js#updateTotals` as before.

## Why these were missed

Dark mode is a list of `.dark .<class>` overrides in `app/assets/tailwind/application.css` (`@layer base`, `!important`), so templates don't need `dark:` variants. A colour that isn't one of those exact classes never gets repainted. All three bugs were that:

| Where | What it looked like in dark mode | Cause | Fix |
|---|---|---|---|
| Desktop builder, "In this order" panel (opened from the Items card) | White panel. Item names, prices and totals already switched to near-white text, so they were nearly invisible. | `_buildOrderPanel` set `background:#fff` and the border **inline**, which no class override can reach. | Background and border are now classes (`bg-white border-t border-gray-200`). Position, size and shadow stay inline. |
| Phone builder, sticky header (title, search, category chips) | A light cream band across the top of an otherwise dark page. | `bg-brand-cream/95` and `border-gray-200/60` are opacity variants, which are different classes from `bg-brand-cream` / `border-gray-200`. | New overrides: `.dark .bg-brand-cream\/95` (page dark at 95%) and `.dark .border-gray-200\/60`. |
| Desktop builder, disabled Create Orders | A normal grey button with white text, so it looked clickable. | `.dark .bg-gray-300` turns the disabled grey into `#4b5563`, the colour of an ordinary button. | `.dark .bg-gray-300.cursor-not-allowed`: `#374151` with `#6b7280` text. |

Also added: `.dark .hover:bg-red-50:hover` gets the same tint as `.dark .bg-red-50`. Without it, hovering the panel's × or the bar's Clear cart showed a pale pink square in dark mode.

## Reach beyond the builder

`bg-gray-300 cursor-not-allowed` is the app's general "disabled" look, so the muted style also applies in dark mode to:

- the below-minimum submit links on `orders/show.html.erb:46` and `orders/show.html+mobile.erb:147`
- the disabled button on `supplier_lists/index.html.erb:67`
- `order_edit_controller.js`'s disabled submit

Plain `bg-gray-300` with no `cursor-not-allowed` (e.g. progress-bar fills) is unchanged. Light mode is unchanged everywhere.

## Verified

WebKit 26 and Chromium, light and dark, on the local dev server. Computed colours were checked, with screenshots:

- Panel: dark `#1f2937` with `#f9fafb` item text. Light mode is still white with dark text.
- Phone header: `rgba(31,41,55,.95)`. Light mode is still cream.
- Disabled Create Orders: `#374151` / `#6b7280`. Light mode is still grey-300 with white text.
- × hover: `rgba(127,29,29,.3)`.

`spec/requests/order_builder_dark_mode_spec.rb` has three examples. All three fail on the old code and pass on the new:

- the disabled button keeps the classes the override targets, and the override exists;
- every translucent `bg-*/N` or `border-*/N` on the phone header has a `.dark` override;
- the panel's background comes from classes, with no inline `background`.

To stop the dev server's in-Puma job runner from refreshing delivery dates (as it did during the audit), dev credential #66's `delivery_dates_fetched_at` was set to now during the check and put back to `nil` afterwards.

## Not changed

- Other opacity variants: `bg-white/10`–`/20` sit on green banners on purpose. `bg-gray-50/50` (6 uses) wasn't seen to break and was left alone.
- The review page's disabled buttons use `bg-gray-600 opacity-50`, a different look that already reads as disabled.
