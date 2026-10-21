# Fix: Safari date fields and the owner's phone picker (Safari only)

Status: **built Oct 21 2026, not committed.** These fix findings #1 and #3b of `docs/safari-audit-2026-10-21.md`.

**Scope rule (Carmin, Oct 21):** "make sure the blast radius on this is confined completely to safari." Both fixes act only in Safari's engine. That means Safari on the Mac, plus every browser on an iPhone or iPad, since Apple makes them all use Safari's engine. Chrome, Edge, Firefox and Android render exactly what they did before (proof below).

**Ordering impact:** the date a chef picks goes into the same field, which posts or saves exactly as before. Create Orders and Submit still stay disabled until a date is set, in every browser. Nothing else in the order flow changed.

## What changed

| File | Change |
|---|---|
| `app/javascript/controllers/safari_date_controller.js` (new) | Its first line exits unless `navigator.vendor` is `"Apple Computer, Inc."`. In Safari it hides the native date field and shows a button instead ("Pick a date" or "Sat, Oct 24", plus a calendar icon). The button opens the month calendar the phone flow already uses. Picking a date sets the hidden field's value and fires the same `input`/`change` events a native pick fires. |
| `app/javascript/controllers/index.js` | Registers `safari-date`. |
| `app/javascript/controllers/mobile_calendar.js` | `openCalendar` takes an optional third argument: `maxIso` greys days after the field's max, and `narrow` keeps the sheet 28rem wide on big screens. Existing phone callers pass nothing and get exactly the old sheet; that's proven below, in Safari too. |
| `app/views/aggregated_lists/order_builder.html.erb` (both bottom-bar copies), `orders/review.html.erb`, `orders/show.html.erb` | Add `data-controller="safari-date"` to the delivery date field. |
| `app/views/dashboard/_owner_dashboard_mobile.html.erb` | Adds class `safari-select-card` to the restaurant picker. |
| `app/assets/tailwind/application.css` | `select.safari-select-card` gets `appearance: none`, room on the right and a chevron. All of it sits inside `@supports (font: -apple-system-body)`, a font keyword only Safari's engine understands. |

## Why these checks

Tested in all three engines (Oct 21):

| Check | Mac Safari | iPhone | Chrome/Edge | Android Chrome | Firefox |
|---|---|---|---|---|---|
| `navigator.vendor` is Apple | yes | yes | no | no | no |
| `@supports (font: -apple-system-body)` | yes | yes | no | no | no |
| `CSS.supports(selector(::-webkit-calendar-picker-indicator))` is false ("no icon") | yes | yes | no | no | **yes** (rejected: it would catch Firefox) |

## Proof that other browsers are unchanged

Captured before and after the change on the local dev server. The pages:

- the builder in light and dark;
- review in light and dark;
- a pending order's page;
- the owner's phone home in light and dark;
- the phone builder's and phone cart's calendar sheets.

That's 10 captures per engine. For each, the HTML (with the new hook attribute/class removed) and the screenshot were compared.

| Engine | HTML | Pixels |
|---|---|---|
| Chromium (Chrome, Edge, Android) | identical, 10/10 | 0 changed, 10/10, apart from the dev timing badge (below) |
| Firefox | identical, 10/10 | 0 changed outside the dev-only timing badge in the top-left corner, whose number (and so its masked box) differs every load |
| WebKit (Safari) | changed only at the date fields and the owner picker | the phone calendar sheets are identical; the page grows where the button is taller |

Safari behaviour, checked in WebKit 26:

- **Builder:** the bar shows the button, never a native field. The calendar opens as a 448px sheet fully on-screen. Picking a date fills all four copies of the field, the autosave goes out, and Create Orders enables.
- **Calendar limits:** days after the field's max (today + 30) are greyed out.
- **Review page:** a pick saves `{"order":{"delivery_date":…}}` (HTTP 200), and the other supplier still asks for a date.
- **Pending order page:** a pick saves (HTTP 200).
- **Owner phone picker:** 45px tall, white, with a chevron, matching Chrome's card.
- No JavaScript errors.

Specs: `spec/requests/safari_date_fields_spec.rb` has 7 examples. They cover:

- the hook on all three pages;
- the existing change handlers left intact;
- the picker class;
- the CSS rule existing only inside the WebKit-only `@supports`;
- the controller exiting first unless the engine is Apple's;
- the calendar's new options being optional.

## Not changed

- Date fields that already work in Safari (prefilled, mid-page, so they only lack an icon) keep the native field: order history and report filters, CRM, supplier portal, the legacy `orders/new` and split preview.
- iPhone home-indicator spacing (#2 in the audit) needs a real iPhone to confirm first.
- The non-Safari findings in the audit are documented, not fixed: Create Orders off-screen on narrow screens, the iPad portrait top bar, and the fonts.
- This was emulated in Playwright WebKit, not tested on a physical iPhone or Mac Safari. A real-device check of one order is still worth doing before relying on it.
