# Safari audit: Oct 21 2026

Status: **two passes on Oct 21**; the second covered what the first skipped (see "Second pass").

- **#1 (date fields) and #3b (owner phone picker): fixed, Safari only.** See `docs/fix-safari-date-fields.md`.
- **Dark-mode gaps: fixed in every browser.** See `docs/fix-dark-mode-ordering-screens.md`.
- **Everything else here is documented, not fixed.**

A chef on Safari tried to create an order. The delivery date field in the order builder's bottom bar showed no calendar icon. The calendar popped up *below* the field, behind the macOS Dock, where he couldn't read it. This audit looks for every Safari-specific visual bug, not just that one.

**Ordering impact: no wrong orders possible, but two things can stop a chef from ordering.**
- An empty delivery date still blocks Create Orders (checked in both engines: the button stays disabled until a real date is set). The review page also refuses to submit without a date. Safari's "today" in an empty field (finding #1b) is display-only and is never sent.
- The Safari date picker (#1c) can be unusable in the bottom bar.
- **Every browser, not Safari:** the builder's bottom bar pushes Create Orders off the right edge of the screen once an order spans enough suppliers for the window width. That means 4+ suppliers on a 1366px laptop, 5+ on 1440px, 6 on 1536px, and 3 on an iPad in portrait. See "Second pass".

---

## Findings: Safari-only

### 1. Native date fields (the chef's bug)

Every date field in the app is a native `<input type="date">`. Safari draws these differently from Chrome in three ways:

| | What Safari does | Verified how |
|---|---|---|
| a | **No calendar icon, ever.** Chrome draws one; Safari never does. | WebKit 26.0 screenshot vs Chromium |
| b | **An empty field shows today's date in dim grey.** It looks like a value but isn't one. The dev chef's builder showed `10/21/2026` while the field's value was `""`. Chrome shows `mm/dd/2026` (placeholder month and day). | WebKit 26.0, DOM value read |
| c | **The calendar always opens downward and never flips up.** The builder's date field sits in the fixed bottom bar, 27px from the bottom of a 900px window, so the calendar lands off-screen or behind the Dock. | The chef's screenshot. Native popups can't be captured headless. Field position measured in WebKit. |

Where it matters, most important first:

- `app/views/aggregated_lists/order_builder.html.erb:172` (desktop bar) and `:116` (narrow-window bar). `order_builder_controller.js` clones this bar into the fixed bottom bar, so both a, b and c apply. **This is the chef's bug.**
- `app/views/orders/review.html.erb:321`: the per-supplier delivery date. The review page clears stale dates, and Safari then shows today's date next to the warning "Select a delivery date to enable submission". The two contradict each other. **Seen in the second pass**: both supplier cards on the dev batch showed `10/21/2026` in normal text, not even dimmed, under that warning.
- `app/views/orders/show.html.erb:202`, `orders/new.html.erb:67`, `orders/split_preview.html.erb:127`: a and b.
- Filters only need the icon (a), because they always hold a value: `orders/index.html.erb:41,45`, `reports/_filter_bar.html.erb:24,28`, `crm/leads/show.html.erb:156`, and three supplier-portal templates.

The phone order flow is **not** affected. It already uses its own month-grid calendar sheet (`app/javascript/controllers/mobile_calendar.js`), which works the same in WebKit as in Chromium.

### 2. iPhone home indicator vs the tab bar (unverified, needs a real iPhone)

`app/views/layouts/application.html+mobile.erb:5` sets `viewport-fit=cover`, which lets the page draw under the iPhone home indicator. Nothing in the mobile layout pads for it:

- `app/views/shared/_mobile_tab_bar.html.erb:4` is `position: fixed; bottom: 0` with only `py-2`.
- The builder ribbon (`order_builder.html+mobile.erb:214`) and the review ribbon (`review.html+mobile.erb:132`) hard-code `bottom: 76px`.

The calendar sheet already pads with `env(safe-area-inset-bottom)`, and `application.css:92` defines a `safe-area-bottom` utility, but nothing applies it to the tab bar. Headless WebKit can't emulate the home indicator, Safari's toolbars, or iOS 26's floating tab bar, so this is a code reading, not an observation. If Home/Order/Cart labels sit under the indicator on a real phone, the tab bar needs `padding-bottom: env(safe-area-inset-bottom)` and both ribbons need to move up by the same amount.

### 3b. Owner's phone location picker renders as a thin native dropdown (second pass)

`app/views/dashboard/_owner_dashboard_mobile.html.erb:64` styles a `<select>` as a white card (`bg-white rounded-xl border px-3 py-2.5 shadow-sm`). Safari ignores padding and most box styling on a `<select>` unless `appearance-none` is set. WebKit draws it as a plain 23px-tall native dropdown; Chrome draws the 42px card. That's an under-sized tap target on the owner/manager phone home. The phone orders filter (`orders/index.html+mobile.erb`) already uses `appearance-none`, which is why it matches across engines. The fix is `appearance-none` plus a chevron icon.

### 3. Oldest Safari that works: 16.4 (no action unless a chef has an old phone)

- Tailwind v4's compiled CSS relies on `@property` (73 uses) and `color-mix()` (188 uses), both Safari 16.4+. Older Safari drops those rules, so colours and opacity utilities break.
- `requestSubmit()` (9 call sites, one with a fallback) needs Safari 16.0+.

Phones stuck on iOS 15 (iPhone 6s, 7, first-gen SE) would see a broken app. The reporting chef is on Safari 26.6.

## Checked and clean

- **Layout.** Every rendered element's size was compared between WebKit and Chromium: 28 pages × desktop (1440×900) and iPhone 15 × light and dark. No layout differences beyond a few pixels of text wrapping, such as one product name wrapping to two lines in a 124px cell.
- **JavaScript.** No exceptions in either engine on any page. Every `new Date(...)` uses ISO or numeric arguments, which Safari parses. The 2FA expiry is sent as `iso8601`.
- **Inputs.** Quantity steppers hide WebKit's spinners (`[&::-webkit-inner-spin-button]:appearance-none`). The 16px rule that stops iOS zooming into inputs is in place.
- **`<summary class="list-none">`** (`aggregated_lists/show.html.erb:119`): WebKit 26 hides the disclosure triangle, just as Chromium does. Tested in isolation, because the sweep's list doesn't render that section.
- **Selects** render as native macOS popups with up/down chevrons. They look different from Chrome's but work.
- **Interactions.** The avatar menu, the builder's "In this order" panel and the phone calendar sheet behave the same in both engines.

## Found along the way: every browser, not Safari

These showed up in the sweep but happen in Chrome too.

- **Brand fonts never load, anywhere, and that is now deliberate.** `app/assets/builds/inter-font.css` imports Oswald and Open Sans from `fonts.googleapis.com`. The CSP in `config/initializers/secure_headers.rb` (`style_src`/`font_src 'self'`) blocks that in every browser. Production's header confirms it (checked Oct 21). The import and the CSP arrived in the same commit (64460b7, Jan 31), so the fonts have never loaded in any environment. Every page has always rendered in the system font. The same CSP blocks the Unsplash hero image on the dashboards (`img_src`); its `onerror` hides it, leaving the plain green banner.
  - Loading the fonts would turn every heading into Oswald (condensed) and the body into Open Sans (slightly wider, so long names truncate sooner). Side-by-side screenshots were made Oct 21. The approved phone comps in `mockups/mobile-first/` were drawn with these fonts, which is the only place they ever showed.
  - **Decision (Carmin, Oct 21 2026): leave it as is.** "If it has been blocking all along I don't want to upset the apple cart now." No change to the CSP, the font import, or the hero image. If this is revisited, the options were: self-host the fonts (keeps the CSP strict), allow Google Fonts in the CSP, or remove the import and the Oswald/Open Sans declarations so the system font is official.
- **Dark mode gaps: fixed Oct 21, see `docs/fix-dark-mode-ordering-screens.md`.**
  - The desktop builder's "In this order" panel rendered white with pale text.
  - The phone builder's sticky header stayed light.
  - The disabled Create Orders button looked like an enabled grey button.
- **`/order_lists/:id/price_comparison` returns a 500** for list 8: `undefined method 'supplier_products' for nil` at `app/services/orders/price_comparison_service.rb:62`. This is a legacy page, linked only from split preview's Cancel.

## Second pass (Oct 21, same day)

The first pass skipped the review and cart pages, used only the chef role, tried only a few interactions, and didn't test iPad. This pass covered those gaps, in WebKit and Chromium, light and dark:

- **Review and cart**, desktop and phone. Opening the phone cart's delivery-date sheet. Order show, new order, batch progress.
- **Builder interactions:** the desktop search filter, +/− steppers, the CS/PC toggle, phone search, and tapping a phone price cell (cell morph).
- **Owner role** (desktop and phone): dashboard, reports, savings, missed savings, organization, locations, suppliers, order lists, orders.
- **iPad** in landscape (1180×820) and portrait (820×1180). iPad Safari sends a Mac user agent, so it gets the desktop layout with touch; emulated that way, in WebKit.

**Results:**
- No JavaScript errors on any of these pages, in either engine.
- Interactions behave the same in both engines.
- The review page's empty-date display is confirmed (#1 above).
- The owner phone location picker is new (#3b above).
- The builder's bottom bar overflows, in every browser (below).
- iPad portrait scrolls sideways, in every browser (below).

### Builder bottom bar hides Create Orders (every browser; hits iPads and laptops)

The desktop builder's fixed bottom bar is one non-wrapping row:

- the Items and Total cards
- one mini-card per supplier with items in the order (~117px each)
- the Delivery field
- Clear cart / Cancel / Create Orders

When the row is wider than the window, the right end runs off-screen. The bar is fixed, so scrolling doesn't bring it back. Measured with the supplier cards revealed in the DOM, identical in WebKit and Chromium:

| Suppliers in the order | Create Orders clipped | Create Orders fully off-screen |
|---|---|---|
| 3 | — | 1024px and narrower: iPad portrait, 1024px iPads |
| 4 | 1366px and narrower | — |
| 5 | 1440–1536px | 1366px and narrower |
| 6 | 1680px | 1536px and narrower |

Common laptop widths are 1280–1536px (MacBook Air 1440/1470, 14" MacBook Pro 1512). The workaround is zooming the browser out. Phones use a different layout and are unaffected. Not yet checked: how many suppliers real orders span. That needs a read-only production query, which needs Carmin's OK.

### iPad portrait: the top bar overflows

At 820px the desktop nav doesn't fit. Labels wrap ("Order / History"), New Order squeezes, the avatar is cut off at the right edge, and every page is 834px wide in an 820px window, so it scrolls sideways. Landscape (1180px) is fine.

### Test artifact, not a finding

WebKit ran first, and its taps autosaved two extra lines into the dev chef's saved order. Chromium then loaded a different cart ($53.60 WCW line), which showed up as a size "difference". The saved order was restored from a snapshot afterwards.

### Still needs a real iPhone or Mac Safari

These can't be reproduced in headless WebKit:

- **Home indicator:** tab bar and ribbons vs the home indicator (#2).
- **iOS 26 tab bar:** Safari's floating tab bar over fixed bottom bars.
- **Outside taps:** phone menus that close on a tap outside (`dropdown_controller.js` listens on `document`; iOS Safari doesn't always send taps on plain areas there).
- **Native popups:** the date picker and select menus. The chef's screenshot is the only evidence for those.

The mobile layout already handles one iOS quirk: after the keyboard closes, it nudges the scroll so the tab bar comes back (`application.html+mobile.erb:184`).

### How the second pass avoided side effects (dev only)

- **Review page:** loading it re-verifies prices live when the last check is over an hour old. Orders 440/441's `price_verified_at` was set to now for the run.
- **Builder:** credential #66's delivery-date refresh was paused, as in the dark-mode check.
- **Owner role:** the dev owner (`owner@testing.com`) got a temporary generated password.
- **Builder taps** autosaved into `CurrentOrder` #2.

All of it was snapshotted first and restored afterwards (orders' timestamps, the saved order's lines and date, the owner's original password hash, the credential). No jobs were queued and no supplier was contacted.

## Proposed fix for #1 (built Safari-only, see `docs/fix-safari-date-fields.md`)

On the ordering path (the builder bar's two copies, review, order show), replace the visible date field with a button that shows the chosen date, or "Pick a delivery date" when empty, plus a calendar icon. The button opens the same month-grid calendar the phone flow uses (`openCalendar` in `mobile_calendar.js`). A hidden date input keeps the value, so the form post and the existing builder/review JS read it unchanged.

- **Gains:** looks and works the same in every browser. It opens as a sheet from the bottom, so it can't fall off-screen. There's no fake "today".
- **Needs:**
  - The calendar must honour a max date (today + 30 days, as the fields do now). Today it only enforces min = tomorrow.
  - A narrower, centred sheet on wide screens.
  - A spec for the hidden-input sync.
- **Filters** (orders index, reports, CRM, supplier portal) keep native fields. A calendar icon is optional there.

Rejected: keep the native field and draw our own icon/placeholder over Safari's. That fixes a and b, but not c, the calendar opening off-screen, which is what stopped the chef.

## Method

- Playwright WebKit 26.0, the same engine generation as Safari 26.6, against Chromium. Headless, on the local dev server, logged in as the dev chef. Scripts and screenshots were kept outside the repo, in the session scratchpad.
- **Not covered:**
  - Native popups (date picker, select menus) aren't drawn in headless screenshots.
  - Real iOS Safari: no simulator is installed, so iPhone sizes were emulated in WebKit.
  - First pass only: `/orders/review` and `/orders/cart` weren't loaded, iPad wasn't tested, and only the chef role was used. The second pass covered all three.
  - Report charts with data: the dev owner's reports have no orders in range, so the charts rendered empty.
- **What didn't work:** Playwright's keyboard typing into WebKit date fields produced `10/21/0026`. That's a harness artifact, so it's not claimed as a Safari bug.

## Side effects of the audit (dev only)

Each builder visit queues `FetchSyscoDeliveryDatesJob` for the dev chef's Performance credential (#66). The dev server runs Solid Queue inside Puma, so 24 of these ran. Each made one token-refresh request to Performance's B2C with an already-expired refresh token, and each was rejected (`AADB2C90080`). There was no password sign-in, and no account data was read or changed. Cleanup:

- The 12 failed job rows were deleted.
- `CurrentOrder` #2's delivery date, changed by a typing test, was restored to Aug 27.
- No `Order` or `SupplierCredential` rows changed.
