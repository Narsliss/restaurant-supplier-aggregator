# Claude Code Context for SupplierHub

## Project Overview
SupplierHub is a restaurant supplier aggregation platform that helps restaurants compare prices and order from multiple food suppliers (US Foods, Chef's Warehouse, What Chefs Want, Premiere Produce One).

## Tech Stack
- **Backend**: Ruby on Rails 7.1.6, Ruby 3.3.6
- **Database**: SQLite
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
- `staggered_supplier_import` - Every hour (rotating supplier imports)
- `deep_catalog_import` - Daily at 2 AM (US Foods deep category browsing)
- `refresh_sessions` - Every 2 hours (proactive session keepalive)
- `discontinue_stale_products` - Daily at 3 AM (discontinue products missing from 3+ consecutive imports)
- `expire_2fa_requests` - Every 5 minutes

Queue configuration in `config/queue.yml` with priorities: critical, default, scraping, low.
Job dashboard: Mission Control at `/jobs` (super_admin only).

## Railway Deployment

### Services
- **web**: Rails app (Puma), PORT=8080
- **worker**: Solid Queue (PROCESS_TYPE=worker)
- **SQLite**: File-based database (also backs queue, cache, and cable via Solid Stack)

### Environment Variables (Railway)
```
RAILS_ENV=production
RAILS_LOG_TO_STDOUT=true
RAILS_SERVE_STATIC_FILES=true
SECRET_KEY_BASE=<generated>
DATABASE_PATH=/data/production.sqlite3
PROCESS_TYPE=web|worker
```

### Deployment Commands
```bash
# Deploy web service
railway up --service web --detach

# Deploy worker service
railway up --service worker --detach

# Check status
railway service status --service web
railway service status --service worker

# View logs
railway logs --service web
railway logs --service worker
```

### Railway URLs
- App: https://web-production-0bed.up.railway.app
- Health: https://web-production-0bed.up.railway.app/up

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
9. Migrated from PostgreSQL to SQLite — zero external service dependencies
