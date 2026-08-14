# Known issues — August 2026

Found while writing the role-based training guides. Every claim in those guides
was checked line-by-line against this codebase; these are the places where the
app and the documentation disagreed, and the app was wrong.

Ordered by how much damage each one does. File references are `path:line` as of
commit `d515202`.

---

## 1. New users are told to set a 6-character password, but 8 is required

**Severity:** high — it's the first screen a new chef or manager ever sees.

`config/initializers/devise.rb:19` sets `config.password_length = 8..128`, and
the helper text underneath the field renders the real number from
`@minimum_password_length`. But the placeholder is hardcoded:

```erb
# app/views/devise/registrations/new.html.erb:156
placeholder: "At least 6 characters"
```

So the field says 6, the hint says 8, and anyone who trusts the placeholder gets
rejected on their first submit — while accepting an invitation, before they've
ever used the product.

**Fix:** interpolate the real value.

```erb
placeholder: "At least #{@minimum_password_length} characters"
```

Then grep for other hardcoded "6 characters" strings.

---

## 2. `submit_batch` and `review` aren't operator-gated

**Severity:** high — it's an authorization gap, not a cosmetic one.

`app/controllers/orders_controller.rb:6`:

```ruby
before_action :require_operator!, only: [:new, :create, :edit, :update, :destroy,
                                          :submit, :reorder, :select_list]
```

`review` (`:373`) and `submit_batch` (`:599`) are both absent from that list.
The per-supplier **Submit Order** button posts to `submit` and is correctly
blocked, but the batch button on the review screen posts to `submit_batch` and
is not. `Return to Checkout` in `app/views/orders/index.html.erb:128,248` isn't
role-gated either, so the path is fully reachable in the UI.

Net effect: **a manager can open a chef's draft batch and place the orders for
real.** For a manager, `scoped_credentials` returns the location's credentials,
so the credential check at `review.html.erb:634-637` passes.

**Decide first, then fix.** Either:

- managers genuinely shouldn't place orders → add `:review, :submit_batch` to
  the `require_operator!` list, and hide `Return to Checkout` behind
  `if operator?`; or
- this is intentional (a manager unblocking a chef who's gone home) → leave the
  code and say so in the guides, which currently tell managers they can't place
  orders.

Same question applies to the delete button in `orders/index.html.erb:183-190`:
it renders for managers and then fails, which is the worst of both.

---

## 3. Product matching has no operator guard

**Severity:** medium — same shape as #2, lower blast radius.

`app/controllers/aggregated_lists_controller.rb:4-8` guards on
`require_location_context!`, `require_owner!` (promote/demote only),
`require_not_promoted!` and `require_list_location_access!` — the last of which
is purely location-based. There's no `require_operator!` anywhere, and
`ProductMatchesController#require_list_write_access!` (`:93-105`) is the same.

Since a manager always has a location in context, a manager can edit product
matches at their own restaurant. The avatar-menu link is hidden from them
(`shared/_navigation.html.erb:157`), so it isn't discoverable — but
`reports/missed_savings.html.erb:24` links straight to it with a
**Go to Product Matching** button, and that button isn't role-gated.

**Fix:** decide whether managers should curate matching. If yes, give them the
menu link — the capability without the link is the worst outcome. If no, add the
guard and gate that button.

---

## 4. The order-guides screen is dead code

**Severity:** medium — a whole feature is unreachable.

`app/controllers/supplier_lists_controller.rb:7-11`:

```ruby
def index
  # This page is no longer the primary UI — redirect to credentials page.
  redirect_to supplier_credentials_path
end
```

Nothing links to `supplier_lists_path` or `supplier_list_path` anywhere in
`app/views` except `supplier_lists/index.html.erb` itself — the view that no
longer renders. Consequences:

- **`Sync Supplier Lists` can't be pressed.** `sync_all` (`:26-36`) is the only
  code path that syncs one credential per supplier to avoid double-scraping the
  same account, and it has no reachable trigger.
- Individual guide pages (`supplier_lists#show`) only load if you have the URL,
  which means the per-guide **Update List** button is unreachable too.
- `SupplierList#sync_status` renders four status badges (Up to Date / Updating /
  Failed / Pending) that no user can see.

**Fix:** either restore an entry point — a "Order guides" section or per-supplier
guide links on the Supplier Credentials page, plus a `Sync all` button wired to
`sync_all` — or delete the dead view and route so it stops looking like a
feature.

---

## 5. The 2FA countdown contradicts itself

**Severity:** low, but it makes people abandon a code that's still valid.

```erb
# app/views/supplier_credentials/index.html.erb:209
# app/views/supplier_credentials/index.html+mobile.erb:133
Codes expire in ~2 minutes!
```

Nothing expires in 2 minutes. `Authentication::TwoFactorHandler::TIMEOUT_MINUTES`
and `Supplier2faRequest::TIMEOUT_MINUTES` are both 5; US Foods and Sysco issue
5-minute codes; Premiere Produce One issues 3. The live `tfaTimer` countdown
right next to this text shows the real value, so the screen disagrees with
itself.

**Fix:** drop the hardcoded string and let the countdown speak, or render the
supplier's actual timeout.

---

## Smaller things

| What | Where | Note |
|---|---|---|
| Billing links render as plain black text | `app/views/subscriptions/show.html.erb:128,169,172` | `text-primary-600` isn't in the compiled Tailwind — no such colour is defined. `Contact Support`, `View` and `PDF` don't look clickable. |
| Menu planner status is hardcoded | `app/views/event_plans/_header.html.erb:30` | Always prints `Drafting`, never `event_plan.status`. A finalized or ordered plan still reads "Drafting". |
| A locked account has no unlock path | `config/initializers/devise.rb:25-28` | `unlock_strategy = :time`, 1 hour. That's fine, but there's no owner-facing unlock and no UI that says how long the wait is. |
| Chefs can't reach Supplier Credentials on mobile | `dashboard/_chef_dashboard_mobile.html.erb:28-46` | The avatar menu has Settings / Feedback / theme / Sign out only. The single route in is the **Fix** button on the credential-health alert, which only appears once something is already broken. Managers get a proper Suppliers link (`_manager_dashboard_mobile.html.erb:75`); chefs don't. |
| Manager mobile has a dead quick link | `dashboard/_manager_dashboard_mobile.html.erb` | **Search** points at Price Check, which is `require_operator!`, so it silently returns them to the dashboard. |
| `CLAUDE.md` schedule is out of date | `CLAUDE.md` vs `config/recurring.yml:24-27` | Doc says catalogs at 5 AM; `recurring.yml` says `0 6 * * *` (6 AM UTC / 2 AM Eastern). `expire_2fa_requests` is also listed twice with different intervals (15 min and 5 min); the file says 5. |
| Sysco is undocumented | `db/seeds.rb:10-69` | Five web suppliers are seeded, not four, and `Scrapers::SyscoScraper` handles 2FA. Sysco appears in the credential dropdown. The training guides deliberately cover only the four this customer uses. |

---

## What the guides currently say

The training guides in `enplacepro-website/guides/` were written against the
behaviour above, with the defect-reporting language removed. Two places state
things that stop being true the moment #2 or #3 is fixed:

- **Manager guide → "Order history"** says a manager can use `Return to Checkout`
  and submit a batch.
- **Manager guide → "Reports"** says a manager can correct product matching.

Grep `guide_manager.py` and `guide_owner.py` for "Return to Checkout" and
"Product Matching" when either issue is closed.
