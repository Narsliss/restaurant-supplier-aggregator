# Product Requirements Document: Demo Environment

**Feature Name**: Ephemeral Sales Demo Environment
**Status**: Draft
**Date**: 2026-03-19

---

## 1. Executive Summary

A hosted demo instance of EnPlace Pro pre-loaded with realistic restaurant data that resets every night at midnight. No supplier connections, no Chromium, no Stripe. Same codebase — just a fat seed script, two order-flow guards, and a lighter Docker image.

---

## 2. What Actually Needs to Change

### Code Changes (4 small touches)

**1. PriceVerificationJob — skip when no Chromium**

The review page auto-fires `PriceVerificationJob` for pending orders. Without Chromium this crashes. Use the same pattern email suppliers already use:

```ruby
# app/jobs/price_verification_job.rb
def perform(order_id)
  order = Order.find(order_id)

  # No browser available — skip verification (same as email suppliers)
  unless chromium_available?
    order.update!(verification_status: 'skipped')
    return
  end

  # ... existing flow
end

private

def chromium_available?
  File.exist?('/usr/bin/chromium') || File.exist?('/usr/bin/chromium-browser') || File.exist?('/usr/bin/google-chrome')
end
```

**2. PlaceOrderJob — skip when no Chromium**

```ruby
# app/jobs/place_order_job.rb
def perform(order_id, ...)
  order = Order.find(order_id)

  unless chromium_available?
    order.update!(status: 'submitted', submitted_at: Time.current)
    return
  end

  # ... existing flow
end
```

Both guards use the same `chromium_available?` check. No env var needed — if there's no browser binary, there's nothing to automate. This is safe everywhere: production has Chromium so the check passes; the demo image doesn't, so it skips.

**3. Demo banner in application layout**

```erb
<%# app/views/layouts/application.html.erb %>
<% if ENV['DEMO_MODE'] == 'true' %>
  <div class="bg-amber-500 text-white text-center text-sm py-1.5 font-medium">
    Demo Environment — Sample data resets nightly at midnight
  </div>
<% end %>
```

**4. Login page role-picker cards**

```erb
<%# app/views/devise/sessions/new.html.erb %>
<% if ENV['DEMO_MODE'] == 'true' %>
  <div class="grid grid-cols-2 gap-3 mb-6">
    <% [
      { name: "Marco Rossi", role: "Owner", email: "marco@demo.supplierhub.com" },
      { name: "Sarah Chen", role: "Manager", email: "sarah@demo.supplierhub.com" },
      { name: "James Wilson", role: "Chef", email: "james@demo.supplierhub.com" },
      { name: "Maria Lopez", role: "Chef", email: "maria@demo.supplierhub.com" }
    ].each do |user| %>
      <button data-email="<%= user[:email] %>" data-password="Demo1234!"
              class="...">
        <strong><%= user[:name] %></strong>
        <span><%= user[:role] %></span>
      </button>
    <% end %>
  </div>
<% end %>
```

**That's it for code changes.** Everything else — dashboards, matching, order builder, reports, role switching — works unchanged because the data is in PostgreSQL.

---

## 3. Why No Other Guards Are Needed

| Concern | Why it's already handled |
|---------|------------------------|
| Scraper jobs fire on schedule | They look up active credentials → find fake ones → try to open browser → no Chromium → job fails harmlessly and logs an error |
| Someone connects a real supplier | They can't — there's no Chromium to run the auth flow. Credential creation would fail at session establishment |
| Stripe charges someone | No `STRIPE_SECRET_KEY` env var on the demo instance → Stripe SDK raises immediately |
| Session refresh jobs | Same as scrapers — no Chromium, fail harmlessly |
| 2FA verification flow | Works but goes nowhere — no real supplier to send a code |

The absence of Chromium and Stripe keys is the baby gate. No code needed.

---

## 4. Demo Seed Script

This is the real work. A `db/seeds/demo.rb` file (~400-500 lines) that creates:

### Users & Organization

| User | Role | Email | Password |
|------|------|-------|----------|
| Marco Rossi | Owner | marco@demo.supplierhub.com | Demo1234! |
| Sarah Chen | Manager | sarah@demo.supplierhub.com | Demo1234! |
| James Wilson | Chef (Downtown) | james@demo.supplierhub.com | Demo1234! |
| Maria Lopez | Chef (Midtown) | maria@demo.supplierhub.com | Demo1234! |

**Organization**: "Rossi Restaurant Group"
**Locations**: Downtown Kitchen, Midtown Bistro

### Supplier Data (Pre-loaded, no scraping)

| Layer | What | Quantity |
|-------|------|----------|
| SupplierProducts | Catalog items per supplier | ~150-200 each, ~600-800 total |
| SupplierLists | Order guides per supplier per location | 1-2 per supplier |
| SupplierListItems | Items on each guide with prices | ~100-150 per list |
| AggregatedList | One promoted matched list | 1 (org-wide) |
| ProductMatches | Matched rows across suppliers | ~120 confirmed, ~20 auto, ~10 unmatched |
| ProductMatchItems | Supplier options per match | 2-4 per match |

Products need realistic names, pack sizes, and prices with intentional price differences across suppliers so the comparison UI is compelling:

```
"Boneless Skinless Chicken Breast"
  US Foods:        $45.99 / 40 LB Case
  Chef's Warehouse: $52.30 / 4x10 LB Case
  What Chefs Want:  $48.75 / 40 LB Case
  → BEST: US Foods ($1.15/lb vs $1.31/lb vs $1.22/lb)
```

### Order Lists & Orders

| Data | Details |
|------|---------|
| Order Lists | 3-4 templates ("Weekly Produce", "Protein Order", "Dry Goods & Pantry") |
| Orders | 12-15 orders over the past 30 days, mix of submitted/confirmed statuses |
| Order Items | 5-15 items per order with realistic quantities |
| Spending data | $40K-60K total monthly spend (makes dashboards look real) |
| Savings | $500-$2K in savings (shows value proposition) |

### Fake Credentials

Per supplier, per location — marked `active` with fake session data:
```ruby
SupplierCredential.create!(
  user: chef_user,
  supplier: us_foods,
  location: downtown,
  username: "demo@rossirestaurants.com",
  password: "not-a-real-password",  # encrypted by model
  status: "active",
  session_data: '{"cookies": []}',  # non-nil so UI shows "Connected"
  last_synced_at: 1.day.ago
)
```

---

## 5. Nightly Reset

A recurring Solid Queue job:

```ruby
# app/jobs/demo_reset_job.rb
class DemoResetJob < ApplicationJob
  queue_as :critical

  def perform
    return unless ENV['DEMO_MODE'] == 'true'

    Rails.logger.info "[DEMO] Nightly reset starting..."

    # Disable foreign key checks, truncate everything except
    # suppliers (managed by initializer) and schema tables
    skip = %w[schema_migrations ar_internal_metadata suppliers supplier_requirements]

    ActiveRecord::Base.connection.execute(
      "SET session_replication_role = 'replica';"
    )
    (ActiveRecord::Base.connection.tables - skip).each do |table|
      ActiveRecord::Base.connection.execute("TRUNCATE TABLE #{table} CASCADE;")
    end
    ActiveRecord::Base.connection.execute(
      "SET session_replication_role = 'origin';"
    )

    # Re-seed
    load Rails.root.join('db/seeds/demo.rb')

    Rails.logger.info "[DEMO] Nightly reset complete."
  end
end
```

```yaml
# config/recurring.yml (only runs on demo — job self-guards)
demo_nightly_reset:
  class: DemoResetJob
  schedule: "0 0 * * *"
  description: "Reset demo environment to golden state"
```

Safe in production — the job checks `DEMO_MODE` and returns immediately.

---

## 6. Dockerfile

Add a build arg to skip Chromium:

```dockerfile
ARG INSTALL_CHROMIUM=true
RUN if [ "$INSTALL_CHROMIUM" = "true" ]; then \
      apt-get install -y chromium chromium-driver; \
    fi
```

Build demo image: `docker build --build-arg INSTALL_CHROMIUM=false .`

---

## 7. Railway Deployment

```
New Railway services:
├── demo-web      (DEMO_MODE=true, INSTALL_CHROMIUM=false)
├── demo-worker   (DEMO_MODE=true, PROCESS_TYPE=worker)
└── demo-postgres (new PostgreSQL instance)
```

Same repo, same branch. Just different env vars.

---

## 8. Effort Estimate

| Task | Effort | Notes |
|------|--------|-------|
| Demo seed script | 4-6 hours | Bulk of the work — ~500 lines of realistic data |
| Chromium guard on PriceVerificationJob | 15 min | 5 lines |
| Chromium guard on PlaceOrderJob | 15 min | 5 lines |
| Demo banner in layout | 15 min | 3 lines of ERB |
| Login role-picker cards | 1 hour | Stimulus controller for click-to-fill |
| DemoResetJob + recurring.yml entry | 30 min | Mostly written above |
| Dockerfile build arg | 15 min | One conditional line |
| Railway service setup | 30 min | Create services, set env vars, deploy |
| **Total** | **~1 day** | Most of it is writing the seed script |

---

## 9. What Works With Zero Changes

Everything except order submission:

- Dashboards (all three roles) — renders from seeded order/spending data
- Product matching — confirm, reject, reassign, search
- Price comparison with BEST badges — calculated from seeded prices
- Order lists — create, edit, duplicate, favorite
- Order builder — set quantities, see supplier minimums, compare prices
- Order history — filters, search, status badges
- Reports — spending by supplier, by restaurant, by team member
- Multi-location switching
- Team management — invite users, assign roles
- List promotion/demotion
- Dark mode

---

## 10. Open Questions

1. Should the nightly reset be EST midnight or UTC?
2. Should we hide the "Connect Supplier" nav item entirely in demo, or let people see it but show "all suppliers connected"?
3. Do we want a manual reset button for the sales team, or is nightly enough?
