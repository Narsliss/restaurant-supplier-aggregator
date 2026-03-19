# Demo Environment Setup Guide

Step-by-step instructions to set up the SupplierHub demo environment on Railway.

---

## Prerequisites

- Railway CLI installed (`railway --version`)
- Logged into Railway (`railway login`)
- GitHub repo: `Narsliss/restaurant-supplier-aggregator`

---

## Part 1: Code Changes (Before Deploying)

### 1.1 Add Chromium build arg to Dockerfile

Replace the Chromium install block in the final stage with a conditional:

```dockerfile
# In the final production image stage, replace the Chromium install block with:
ARG INSTALL_CHROMIUM=true
RUN if [ "$INSTALL_CHROMIUM" = "true" ]; then \
      apt-get update -qq && \
      apt-get install --no-install-recommends -y \
        chromium chromium-driver fonts-liberation libasound2 \
        libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 libcups2 \
        libdbus-1-3 libdrm2 libgbm1 libgtk-3-0 libnspr4 libnss3 \
        libxcomposite1 libxdamage1 libxfixes3 libxkbcommon0 \
        libxrandr2 xdg-utils && \
      rm -rf /var/lib/apt/lists /var/cache/apt/archives; \
    fi
```

### 1.2 Add demo guards to order jobs

**PriceVerificationJob** — add early return:
```ruby
def perform(order_id)
  order = Order.find(order_id)
  if ENV['DEMO_MODE'] == 'true'
    order.update!(verification_status: 'skipped')
    return
  end
  # ... existing code unchanged
end
```

**PlaceOrderJob** — add early return:
```ruby
def perform(order_id, ...)
  order = Order.find(order_id)
  if ENV['DEMO_MODE'] == 'true'
    order.update!(status: 'submitted', submitted_at: Time.current)
    return
  end
  # ... existing code unchanged
end
```

### 1.3 Add demo banner to layout

In `app/views/layouts/application.html.erb`, right after `<body>`:
```erb
<% if ENV['DEMO_MODE'] == 'true' %>
  <div class="bg-amber-500 text-center text-sm py-1.5 font-semibold text-white tracking-wide">
    Demo Environment — Sample data resets nightly at midnight
  </div>
<% end %>
```

### 1.4 Add login role-picker to sign-in page

In `app/views/devise/sessions/new.html.erb`, add a demo card section gated by `ENV['DEMO_MODE']` with quick-login buttons for each seeded user.

### 1.5 Create DemoResetJob

```ruby
# app/jobs/demo_reset_job.rb
class DemoResetJob < ApplicationJob
  queue_as :critical

  def perform
    return unless ENV['DEMO_MODE'] == 'true'
    Rails.logger.info "[DEMO] Nightly reset starting..."

    skip = %w[schema_migrations ar_internal_metadata suppliers supplier_requirements]
    ActiveRecord::Base.connection.execute("SET session_replication_role = 'replica';")
    (ActiveRecord::Base.connection.tables - skip).each do |table|
      ActiveRecord::Base.connection.execute("TRUNCATE TABLE #{table} CASCADE;")
    end
    ActiveRecord::Base.connection.execute("SET session_replication_role = 'origin';")

    load Rails.root.join('db/seeds/demo.rb')
    Rails.logger.info "[DEMO] Nightly reset complete."
  end
end
```

### 1.6 Add to recurring.yml

```yaml
demo_nightly_reset:
  class: DemoResetJob
  schedule: "0 4 * * *"    # 4 AM UTC = midnight EST
  description: "Reset demo environment to golden state"
```

### 1.7 Create demo seed from dev database

```bash
# Dump your local dev database (data only, no schema)
pg_dump --data-only --no-owner --no-privileges \
  --exclude-table='schema_migrations' \
  --exclude-table='ar_internal_metadata' \
  --exclude-table='solid_queue_*' \
  --exclude-table='solid_cache_*' \
  --exclude-table='solid_cable_*' \
  supplier_hub_development > db/seeds/demo_data.sql
```

Then create `db/seeds/demo.rb`:
```ruby
# db/seeds/demo.rb
conn = ActiveRecord::Base.connection

# Restore the data snapshot
sql = File.read(Rails.root.join('db/seeds/demo_data.sql'))
conn.execute(sql)

# Scrub sensitive data
SupplierCredential.update_all(
  session_data: '{"cookies":[]}',
  status: 'active',
  last_synced_at: 1.day.ago
)
# Re-encrypt passwords with dummy values
SupplierCredential.find_each do |cred|
  cred.update_columns(
    password_ciphertext: SupplierCredential.new(password: 'demo-password').password_ciphertext
  )
end

# Set all user passwords to Demo1234!
User.find_each { |u| u.update!(password: 'Demo1234!') }

# Reset sequence counters so new records don't collide
conn.tables.each do |table|
  pk = conn.primary_key(table)
  next unless pk
  conn.execute("SELECT setval(pg_get_serial_sequence('#{table}', '#{pk}'), COALESCE(MAX(#{pk}), 0) + 1, false) FROM #{table};") rescue nil
end
```

### 1.8 Commit and push

```bash
git add -A
git commit -m "Add demo environment support"
git push origin main
```

---

## Part 2: Railway Setup

### Step 1: Create the demo project

```bash
railway init --name "SupplierHub Demo"
```

This creates a new empty project. Note the project ID from the output.

### Step 2: Add PostgreSQL

In the Railway dashboard (https://railway.com/dashboard):

1. Open the "SupplierHub Demo" project
2. Click **+ New** → **Database** → **PostgreSQL**
3. Wait for it to provision (~30 seconds)
4. The `DATABASE_URL` variable is automatically available to other services

> **Why dashboard:** The CLI `railway add --plugin postgresql` works but the dashboard is faster for one-time setup and lets you see the connection string immediately.

### Step 3: Create demo-web service

In the Railway dashboard:

1. Click **+ New** → **GitHub Repo** → Select `Narsliss/restaurant-supplier-aggregator`
2. Railway auto-detects the Dockerfile
3. Rename the service to `demo-web`
4. Go to **Settings**:
   - **Source** → Branch: `main`
   - **Source** → Auto Deploy: **ON**
   - **Build** → Add build arg: `INSTALL_CHROMIUM=false`
5. Go to **Variables** and add:

```
RAILS_ENV=production
PROCESS_TYPE=web
DEMO_MODE=true
SECRET_KEY_BASE=<generate with: openssl rand -hex 64>
RAILS_SERVE_STATIC_FILES=true
RAILS_LOG_TO_STDOUT=true
PORT=8080
```

6. Under **Networking** → Generate a public domain (or add custom domain `demo.supplierhub.com`)

### Step 4: Create demo-worker service

1. Click **+ New** → **GitHub Repo** → Same repo
2. Rename to `demo-worker`
3. **Settings**:
   - Branch: `main`
   - Auto Deploy: **ON**
   - Build arg: `INSTALL_CHROMIUM=false`
4. **Variables**:

```
RAILS_ENV=production
PROCESS_TYPE=worker
DEMO_MODE=true
SECRET_KEY_BASE=<same as demo-web>
RAILS_LOG_TO_STDOUT=true
```

> The worker doesn't need PORT or RAILS_SERVE_STATIC_FILES.

5. Under **Networking** → **No public domain** (worker doesn't serve HTTP)

### Step 5: Link PostgreSQL to both services

Railway usually auto-links the `DATABASE_URL` from the PostgreSQL service to any other service in the same project. Verify:

1. Click on `demo-web` → **Variables** → Confirm `DATABASE_URL` references the PostgreSQL service
2. Same for `demo-worker`

If not present, click **+ Variable** → **Add Reference** → Select the PostgreSQL service → `DATABASE_URL`.

### Step 6: First deploy

Both services should auto-deploy since they're connected to the repo with auto-deploy on. Watch the build logs:

1. `demo-web` builds (~3-5 min first time, no Chromium so faster)
2. Entrypoint runs `db:migrate` (creates all tables)
3. `demo-worker` builds and starts Solid Queue

### Step 7: Seed the demo data

After the first deploy, you need to run the seed script once. Railway doesn't have a one-off `railway run` that works reliably, so add a temporary entrypoint override:

**Option A: Railway console (dashboard)**
1. Click `demo-web` → **Settings** → **Deploy** → Custom start command:
   ```
   bash -c "rails db:seed:demo && rails server -b 0.0.0.0 -p 8080"
   ```
2. Wait for it to deploy and seed
3. Remove the custom start command and redeploy

**Option B: Add a seed-on-first-boot check to bin/start**
```bash
# bin/start — add before the case statement:
if [ "$DEMO_MODE" = "true" ] && [ "$PROCESS_TYPE" = "web" ]; then
  echo "Demo mode: checking if seed is needed..."
  USERS=$(./bin/rails runner "puts User.count" 2>/dev/null || echo "0")
  if [ "$USERS" = "0" ]; then
    echo "No users found — running demo seed..."
    ./bin/rails runner "load Rails.root.join('db/seeds/demo.rb')"
    echo "Demo seed complete."
  fi
fi
```

This auto-seeds on boot if the database is empty, which also handles the nightly reset (DemoResetJob truncates, then next boot seeds — but actually the job itself re-seeds, so this is just a first-deploy safety net).

---

## Part 3: Verify

### Check demo-web
```bash
curl https://demo-web-xxxx.up.railway.app/up
# Should return 200
```

### Check the UI
1. Open the demo URL in a browser
2. You should see the login page with role-picker cards (if implemented)
3. Log in as any demo user with password `Demo1234!`
4. Verify dashboard shows data, matched lists render, orders exist

### Check demo-worker logs
```bash
railway link -p "SupplierHub Demo" -s demo-worker
railway logs
# Should see Solid Queue starting, DemoResetJob scheduled
```

---

## Part 4: Ongoing Workflow

### Day-to-day: Push once, both environments update

```bash
git push origin main
# Railway auto-deploys:
#   - pretty-friendship (prod web)
#   - worker (prod worker)
#   - demo-web (demo web)
#   - demo-worker (demo worker)
```

> **Wait** — the production services won't auto-deploy unless you also enable auto-deploy on those. Currently you deploy prod manually with `railway up`. You can keep it that way (manual prod, auto demo) or enable auto-deploy on everything.

### Nightly reset

DemoResetJob fires at midnight via `config/recurring.yml`. No manual intervention needed. The worker truncates all data and re-runs the seed script.

### Manual reset (if needed)

SSH into the demo-web service via Railway dashboard → Shell tab:
```bash
rails runner "DemoResetJob.perform_now"
```

---

## Architecture Summary

```
GitHub (main branch)
  │
  ├── Auto-deploy ──→ Railway: "SupplierHub Demo"
  │                     ├── demo-web     (DEMO_MODE=true, no Chromium)
  │                     ├── demo-worker  (DEMO_MODE=true, no Chromium)
  │                     └── demo-postgres
  │
  └── Manual deploy ──→ Railway: "SupplierHub" (existing)
                          ├── pretty-friendship  (production web)
                          ├── worker             (production worker)
                          └── PostgreSQL         (production DB)
```

### Environment Variable Differences

| Variable | Production | Demo |
|----------|-----------|------|
| DEMO_MODE | *(not set)* | `true` |
| PROCESS_TYPE | `web` / `worker` | `web` / `worker` |
| INSTALL_CHROMIUM | `true` (default) | `false` |
| DATABASE_URL | prod PostgreSQL | demo PostgreSQL |
| SECRET_KEY_BASE | prod key | different key |
| STRIPE_SECRET_KEY | real key | *(not set)* |
| RAILS_ENV | production | production |

### Cost

Railway pricing is usage-based. The demo environment will cost:
- **PostgreSQL**: ~$5/mo (small dataset, low traffic)
- **demo-web**: ~$5-10/mo (idle most of the time, no Chromium = less RAM)
- **demo-worker**: ~$3-5/mo (mostly idle, one job per night)
- **Total**: ~$13-20/mo
