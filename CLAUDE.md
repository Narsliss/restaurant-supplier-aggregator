# Claude Code Context for EnPlace Pro

## Project Overview
EnPlace Pro is a restaurant supplier aggregation platform that helps restaurants compare prices and order from multiple food suppliers (US Foods, Chef's Warehouse, What Chefs Want, Premiere Produce One).

## Tech Stack
- **Backend**: Ruby on Rails 7.1.6, Ruby 3.3.6
- **Database**: PostgreSQL
- **Cache/Queue/Cable**: Solid Stack (solid_queue, solid_cache, solid_cable) — no Redis
- **Frontend**: Hotwire (Turbo + Stimulus), Tailwind CSS
- **Browser Automation**: Ferrum (headless Chrome) for supplier scraping
- **Payments**: Stripe (subscriptions)
- **Deployment**: Railway.com (Docker)

## Key Architecture

### Multi-tenant Organizations
- Users belong to Organizations via Memberships
- Roles: owner, admin, manager, member (organization-level)
- System roles: user, super_admin (platform-level)

### Supplier Authentication Types
Two authentication patterns for suppliers:
1. **Password-based** (Chef's Warehouse, What Chefs Want): username + password
2. **2FA-only** (US Foods, Premiere Produce One): email/phone only, verification code sent each login

The `suppliers.password_required` boolean determines which type (default: true).

### Scrapers
Located in `app/services/scrapers/`:
- `BaseScraper` - common functionality, session management
- `UsFoodsScraper` - Azure AD B2C auth, stealth browser options for WAF bypass
- `ChefsWarehouseScraper` - Vue.js SPA, uses JavaScript-based form filling
- `WhatChefsWantScraper` - standard login
- `PremiereProduceOneScraper` - React SPA, passwordless auth

### Background Jobs (Solid Queue)
Recurring jobs in `config/recurring.yml`:
- `staggered_supplier_import` - Daily at 5 AM (catalog import via super_admin credentials)
- `sync_all_lists` - Daily at 8 AM (order guide/list sync, one credential per supplier per org)
- `refresh_sessions` - Every 2 hours (proactive session keepalive)
- `expire_2fa_requests` - Every 15 minutes
- Disabled: `deep_catalog_import`, `discontinue_stale_products` (run on explicit request only)
- `expire_2fa_requests` - Every 5 minutes

Queue configuration in `config/queue.yml` with priorities: critical, default, scraping, low.
Job dashboard: Mission Control at `/jobs` (super_admin only).

## Railway Deployment

### Services
- **web**: Rails app (Puma), PORT=8080
- **worker**: Solid Queue (PROCESS_TYPE=worker)
- **PostgreSQL**: Database (also backs queue, cache, and cable via Solid Stack)

### Environment Variables (Railway)
```
RAILS_ENV=production
RAILS_LOG_TO_STDOUT=true
RAILS_SERVE_STATIC_FILES=true
SECRET_KEY_BASE=<generated>
DATABASE_URL=<postgresql-url>
PROCESS_TYPE=web|worker
```

### Deployment Workflow
**CRITICAL: Always push to GitHub BEFORE deploying to Railway.**
Never deploy untracked code to production. The correct order is:

```bash
# 1. Commit and push to GitHub first (version track it)
git push origin main

# 2. Deploy web service
railway link -s pretty-friendship
railway up --detach

# 3. Deploy worker service
railway link -s worker
railway up --detach

# 4. Verify
railway logs --service pretty-friendship
railway logs --service worker
```

### Railway Commands
```bash
# Check status
railway service status --service pretty-friendship
railway service status --service worker

# View logs (must link to service first)
railway link -s pretty-friendship
railway logs

railway link -s worker
railway logs
```

### Railway URLs
- App: https://enplacepro.app (also https://www.enplacepro.app)
- Health: https://enplacepro.app/up
- NOTE: The old `web-production-0bed.up.railway.app` subdomain was released and is now serving another Railway tenant's Next.js app. Do not use it.

## Local Development

### Setup
```bash
bundle install
bin/rails db:create db:migrate db:seed
```

### Running Locally
```bash
# Start Rails server
bin/rails server

# Start Solid Queue worker (separate terminal)
bin/jobs

# Or use Foreman
foreman start
```

### Docker
```bash
docker build -t supplier-hub .
docker run -p 3000:3000 -e RAILS_ENV=production supplier-hub
```

## Important Files

### Configuration
- `config/queue.yml` - Solid Queue workers and dispatchers
- `config/recurring.yml` - Scheduled/recurring jobs (cron)
- `railway.json` - Railway deployment config
- `Dockerfile` - Multi-stage build with Chromium
- `bin/start` - Entrypoint script (web vs worker based on PROCESS_TYPE)

### Models
- `User` - Devise auth, organization memberships
- `Organization` - Multi-tenant container
- `Supplier` - Supplier config (password_required flag)
- `SupplierCredential` - User's login for a supplier (encrypted)
- `SupplierProduct` - Products scraped from suppliers
- `Subscription` - Stripe subscription

### Key Patterns

#### Vue.js/React SPA Form Filling
For SPAs that re-render DOM, use JavaScript-based filling:
```ruby
browser.evaluate(<<~JS)
  var el = document.getElementById('#{element_id}');
  var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  nativeSetter.call(el, '#{escaped_value}');
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
JS
```

#### Session Persistence
Scrapers save cookies + localStorage + sessionStorage to `supplier_credentials.session_data` for session restoration.

## Testing Credentials (Seeds)
- Demo user: demo@example.com / password123
- Super admin: admin@example.com / admin123

## Git Workflow
- Main branch: `main`
- Working branch: `priceless-brown` (worktree)
- Push to both: `git push origin priceless-brown && git push origin priceless-brown:main`

## Recent Changes (Feb 2025)
1. Added 2FA-only authentication support for US Foods and PPO
2. Fixed Chef's Warehouse Vue.js login with JavaScript-based form filling
3. Added multi-process Docker support (PROCESS_TYPE env var)
4. Deployed to Railway with separate web and worker services
5. All 4 scheduled cron jobs running on worker
6. Migrated to Solid Stack (solid_queue, solid_cache, solid_cable) — removed Redis dependency
7. Added per-unit price comparison for different pack sizes
8. Registered credential-form Stimulus controller for 2FA supplier password field hide
9. Migrated back to PostgreSQL from SQLite
