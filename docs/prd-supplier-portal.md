# Product Requirements Document: Supplier Portal

**Feature Name**: Supplier Analytics Portal
**Status**: Draft
**Branch**: `inventory-module` (experimental)
**Date**: 2026-03-05

---

## 1. Executive Summary

SupplierHub currently serves one side of the marketplace — restaurants. The Supplier Portal opens the platform to the other side by giving suppliers (US Foods, Chef's Warehouse, What Chefs Want, Premiere Produce One) their own login and dashboard where they can see how their products and customers are performing on the platform.

Supplier reps will be able to review their imported product catalog for accuracy, track total order revenue from all their SupplierHub customers, identify best-selling and under-performing products, see which items chefs added to shopping lists but never ordered (cart abandonment), and understand their top-performing customer relationships.

This transforms SupplierHub from a restaurant tool into a **two-sided platform** — creating value for suppliers that deepens their engagement, opens a future revenue channel, and gives restaurants better service from suppliers who now have visibility into ordering patterns.

---

## 2. Problem Statement

Food suppliers currently have limited visibility into how their restaurant customers discover, compare, and order products. Their existing tools show:

1. **Order history from their own portal** — they see what was ordered, but not what was *considered and rejected*
2. **No competitive context** — they don't know when a customer chose a competitor's product instead
3. **Manual account management** — sales reps track customer relationships in spreadsheets or CRMs disconnected from actual ordering data
4. **No product performance analytics** — which SKUs are trending up? Which are being abandoned? Which price changes caused volume drops?
5. **Fragmented customer view** — multi-location restaurant groups appear as separate accounts with no unified picture

| Problem | Impact |
|---------|--------|
| No visibility into shopping list activity | Suppliers miss signals about what chefs are considering but not buying |
| No product performance trends | Can't proactively adjust pricing, availability, or promotions |
| Manual customer tracking | Reps spend time on data gathering instead of relationship building |
| No view across SupplierHub customers | Can't identify growth opportunities or at-risk accounts |
| No catalog accuracy feedback loop | Product data errors (wrong name, pack size, price) go undetected |

---

## 3. Proposed Solution

A dedicated portal at `/supplier` where supplier company representatives log in with their own accounts (completely separate from restaurant user accounts) and access analytics dashboards tailored to their business.

**How it works:**

1. A SupplierHub admin invites the first supplier rep (e.g., a US Foods account manager)
2. That rep logs in and sees a dashboard with KPIs, recent orders, and top products — all scoped to their supplier's data only
3. They can drill into product performance, customer rankings, and cart abandonment insights
4. Supplier admins can invite additional team members and assign them to specific customer accounts

**Key principle:** The portal is **read-only analytics**. Suppliers cannot modify orders, change prices, or access other suppliers' data. All data is derived from existing SupplierHub activity — no new data entry required from anyone.

---

## 4. Target Users

| User | Role | Key Needs |
|------|------|-----------|
| **Account Manager / Sales Rep** | Day-to-day customer relationship management | Which customers are ordering? Which are slipping? What should I pitch? |
| **Regional Sales Director** | Oversees multiple reps and accounts | Aggregate view across all customers, rep performance, growth trends |
| **Product/Category Manager** | Manages product catalog and pricing | Which SKUs are performing? What's the impact of price changes? Are there data accuracy issues? |

### User Roles Within the Portal

| Role | Access Level |
|------|-------------|
| **Supplier Admin** | Full access to all customers, team management, all analytics |
| **Supplier Rep** | Access limited to assigned customers only |

---

## 5. Business Objectives

| Objective | Metric | Target |
|-----------|--------|--------|
| Create a two-sided platform | Supplier portal logins per week | 2+ logins/week per active supplier within 3 months |
| Open future revenue channel | Supplier portal as a monetizable feature | Demonstrate value before pricing discussions |
| Improve catalog accuracy | Product inaccuracy flags submitted by suppliers | Reduce catalog errors by 50% |
| Deepen supplier relationships | Supplier engagement with SupplierHub team | All 4 suppliers actively using the portal |
| Surface actionable data for suppliers | Cart abandonment insights acted on (price change, promotion, outreach) | Measurable follow-up actions |
| Increase platform stickiness | Restaurants benefit from better supplier service driven by portal insights | Indirect — tracked via supplier NPS |

---

## 6. Feature Requirements

### Phase 1: Foundation — Authentication, Dashboard, Product Catalog

> **Goal**: Supplier reps can log in and see a useful overview of their business on SupplierHub, plus review their product catalog.

#### 6.1 Authentication & Access

Supplier users are **completely separate** from restaurant users. They have their own login, their own accounts, and their own Devise authentication scope.

| Requirement | Details |
|-------------|---------|
| Separate login | `/supplier/sign_in` — distinct from the restaurant login at `/users/sign_in` |
| Invitation-only | No self-registration. SupplierHub admin creates the first supplier admin; supplier admins invite their team |
| Password requirements | Same as restaurant users: 8+ characters, lockout after 5 failed attempts |
| Session management | Standard Devise sessions with "Remember me" option |
| Password reset | Self-service via email |
| Account deactivation | Supplier admins or SupplierHub admins can deactivate accounts |

#### 6.2 Dashboard

The landing page after login. Shows a high-level snapshot of the supplier's business on SupplierHub.

| Component | Details |
|-----------|---------|
| **KPI Cards** (top row) | Total Orders · Total Revenue · Active Customers · Active Products · Avg Order Value |
| **30-Day Trend** | Each KPI shows a comparison to the prior 30-day period (e.g., "↑ 12% vs. last month") |
| **Recent Orders** | Table of 10 most recent orders: date, customer (organization name), location, items, total amount, status |
| **Top 5 Products** | Best-selling products in the last 30 days by revenue |
| **Quick Stats** | Products out of stock, products discontinued, new customers this month |

```
┌──────────────────────────────────────────────────────────────────┐
│  📊 Dashboard                                                    │
│                                                                  │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │
│  │  1,247  │ │ $482K   │ │   38    │ │  2,891  │ │  $386   │  │
│  │ Orders  │ │ Revenue │ │ Cust.   │ │Products │ │Avg Order│  │
│  │ ↑ 8%    │ │ ↑ 12%   │ │ ↑ 3     │ │ ─       │ │ ↑ 5%    │  │
│  └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘  │
│                                                                  │
│  Recent Orders                         Top Products              │
│  ┌────────────────────────────┐       ┌──────────────────────┐  │
│  │ Mar 4  Tres Leches  $842  │       │ 1. Roma Tomatoes     │  │
│  │ Mar 4  Blue Bistro   $1.2K│       │ 2. Chicken Breast    │  │
│  │ Mar 3  Café Luna    $567  │       │ 3. Olive Oil EVOO    │  │
│  │ ...                       │       │ 4. Heavy Cream       │  │
│  └────────────────────────────┘       │ 5. All-Purpose Flour │  │
│                                       └──────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

#### 6.3 Product Catalog Review

Suppliers can browse their imported product catalog, verify accuracy, and see product health.

| Requirement | Details |
|-------------|---------|
| Product list | Searchable, filterable table of all SupplierProducts for this supplier |
| Filters | All · In Stock · Out of Stock · Discontinued · Price Changed |
| Search | By product name or SKU |
| Product detail | Name, SKU, current price, previous price, pack size, per-unit price, stock status, last scraped date |
| Flag inaccuracy | Button on any product to report incorrect data (name, price, pack size). Creates a notification for SupplierHub admin |
| Pagination | 50 items per page with total count |

#### 6.4 Product Health Page

A dedicated view focused on catalog quality and issues.

| Section | What It Shows |
|---------|---------------|
| **Out of Stock** | Products marked as out of stock — supplier can verify if this is accurate |
| **Discontinued** | Products marked discontinued (3+ consecutive import misses) — supplier can confirm or flag as error |
| **At Risk** | Products with 1-2 consecutive misses — may be about to be marked discontinued |
| **Stale** | Products not updated in 24+ hours — indicates possible scraping issues |
| **Summary stats** | Total active, out of stock, discontinued, at risk counts |

---

### Phase 2: Customer Insights & Revenue Analytics

> **Goal**: Suppliers can understand their customer relationships and revenue trends.

#### 6.5 Customer Rankings

| Requirement | Details |
|-------------|---------|
| Customer list | All organizations that have ordered from this supplier, ranked by total revenue |
| Per-customer stats | Total revenue, order count, average order value, last order date, number of locations |
| Search | By organization name |
| Churn signals | Visual indicator for customers who haven't ordered in 30+ days (yellow) or 60+ days (red) |
| Rep filtering | Reps see only their assigned customers; admins see all |

#### 6.6 Customer Detail Page

Drill into a specific customer (organization) to see their relationship with this supplier.

| Component | Details |
|-----------|---------|
| **Header stats** | Total revenue, order count, avg order value, last order date, locations count |
| **Order trend** | Weekly order volume and revenue over the last 90 days |
| **Top products** | Top 20 products this customer orders by revenue |
| **Location breakdown** | Revenue and order count per restaurant location |
| **Privacy** | Organization name and location names shown. Individual chef/user names are NOT exposed |

```
┌──────────────────────────────────────────────────────────────────┐
│  ← Customers                                                     │
│                                                                  │
│  Tres Leches Restaurant Group                                    │
│                                                                  │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐              │
│  │ $24.8K  │ │   67    │ │  $370   │ │ Feb 28  │              │
│  │ Revenue │ │ Orders  │ │Avg Order│ │Last Order│              │
│  └─────────┘ └─────────┘ └─────────┘ └─────────┘              │
│                                                                  │
│  Order Trend (Last 90 Days)                                      │
│  ▐ ▐▐ ▐▐▐ ▐▐▐▐ ▐▐▐ ▐▐▐▐ ▐▐▐▐▐ ▐▐▐▐▐ ▐▐▐▐▐▐ ▐▐▐▐▐▐         │
│  Jan          Feb              Mar                               │
│                                                                  │
│  Top Products                  Locations                         │
│  ┌──────────────────────┐     ┌───────────────────────┐         │
│  │ Roma Tomatoes  $3.2K │     │ Main St    $14.2K     │         │
│  │ Chicken Breast $2.8K │     │ Downtown   $10.6K     │         │
│  │ Olive Oil EVOO $1.9K │     │                       │         │
│  └──────────────────────┘     └───────────────────────┘         │
└──────────────────────────────────────────────────────────────────┘
```

#### 6.7 Revenue Analytics

Dedicated analytics page with date range filtering and multiple views.

| View | Details |
|------|---------|
| **Revenue over time** | Weekly bar chart showing revenue and order count. Default: last 90 days |
| **Revenue by customer** | Ranked table: organization name, revenue, order count, % of total |
| **Revenue by location** | Ranked table: location name (with parent org), revenue, order count |
| **Date range filter** | Preset ranges (7d, 30d, 90d, YTD, all time) + custom date picker |
| **Period comparison** | "vs. prior period" percentage change for each metric |

---

### Phase 3: Cart Abandonment & Product Performance

> **Goal**: Suppliers gain insight into products chefs considered but didn't buy, and deep product analytics.

#### 6.8 Cart Abandonment Insights

This is data unique to SupplierHub — no supplier has this visibility today. It surfaces products that chefs added to their shopping lists but never converted into orders.

| Requirement | Details |
|-------------|---------|
| Abandoned products | Products from this supplier that appear in shopping lists but have not been ordered in the last 90 days |
| Per-product stats | Number of shopping lists containing this product, number of unique customers/orgs |
| Stale list items | Products sitting in lists that haven't been used in 30+ days |
| Actionable framing | "These products were considered but not ordered — potential opportunities for outreach, pricing adjustments, or promotions" |

**How cart abandonment is calculated:**

```
"Abandoned" = product exists in one or more OrderListItems
              AND is available from this supplier (via Product → SupplierProduct)
              AND has NOT appeared in a submitted/confirmed Order
                  in the last 90 days
```

| Data Point | Source |
|------------|--------|
| Product is in a shopping list | `OrderListItem.product_id` → `Product` → `SupplierProduct.supplier_id` |
| Product was ordered | `OrderItem.supplier_product_id` → `Order.status IN (submitted, confirmed)` |
| Customer who has it in a list | `OrderList.organization_id` |

```
┌──────────────────────────────────────────────────────────────────┐
│  🛒 Cart Abandonment Insights                                    │
│                                                                  │
│  14 products in shopping lists but not ordered (last 90 days)    │
│  Across 8 customers                                              │
│                                                                  │
│  Product                  In Lists    Customers    Price         │
│  ─────────────────────────────────────────────────────────       │
│  Wagyu Beef Striploin     6 lists     4 orgs       $89.99       │
│  Truffle Oil 8oz          5 lists     3 orgs       $24.50       │
│  Saffron 1oz              4 lists     4 orgs       $18.75       │
│  Duck Confit Legs 4pk     3 lists     2 orgs       $32.00       │
│  ...                                                             │
│                                                                  │
│  💡 These products were considered but not ordered.              │
│     Consider outreach, samples, or promotional pricing.          │
└──────────────────────────────────────────────────────────────────┘
```

#### 6.9 Product Performance Analytics

Deep dive into how individual products perform over time.

| Requirement | Details |
|-------------|---------|
| **Top sellers** | Ranked by quantity ordered and by revenue (separate views) |
| **Bottom performers** | Products ordered fewer than 3 times in the last 90 days |
| **Trending** | Products with increasing order volume (compare last 30d to prior 30d) |
| **Declining** | Products with decreasing order volume |
| **Price change impact** | When a product's price changed, show the before/after order volume to assess elasticity |
| **Product detail** | Per-product page: weekly order trend, top customers ordering it, price history |

#### 6.10 Price Change Impact Analysis

| Requirement | Details |
|-------------|---------|
| Products with recent price changes | List of products where `current_price != previous_price` |
| Before/after comparison | Order volume 30 days before vs. 30 days after the price change |
| Direction indicator | "Price ↑ 8% → Volume ↓ 15%" or "Price ↓ 5% → Volume ↑ 22%" |
| Sensitivity ranking | Products most affected by price changes (largest volume swing) |

---

### Phase 4: Team Management & Polish

> **Goal**: Supplier admins can manage their team, and the portal is production-ready.

#### 6.11 Team Management (Supplier Admins Only)

| Requirement | Details |
|-------------|---------|
| View team | List of all supplier users for this supplier |
| Invite new member | Email invitation with role selection (admin or rep) |
| Assign customers | For reps: assign which organizations/customers they can see |
| Deactivate/reactivate | Disable access without deleting the account |
| Resend invitation | For pending invitations that haven't been accepted |

#### 6.12 Settings

| Requirement | Details |
|-------------|---------|
| Profile | Update name, email, phone |
| Password | Change password |
| Notification preferences | Email digest frequency (daily, weekly, never) |

#### 6.13 Mobile Responsiveness

| Requirement | Details |
|-------------|---------|
| Responsive layout | All pages must work on tablet and mobile |
| Card stacking | KPI cards stack vertically on small screens |
| Table alternatives | Tables convert to card lists on mobile |
| Touch targets | Minimum 44px touch targets for mobile |

#### 6.14 Dark Mode

| Requirement | Details |
|-------------|---------|
| Theme toggle | Same light/dark toggle as the main app |
| Consistent styling | All portal pages support both themes |

---

## 7. Data Model

### New Tables

```
┌────────────────────────┐       ┌──────────────────┐
│      Supplier          │       │   Organization    │
│   (existing model)     │       │ (existing model)  │
└──────────┬─────────────┘       └────────┬─────────┘
           │ has_many                      │
           │                               │
    ┌──────▼──────────────┐                │
    │   SupplierUser       │                │
    │                      │                │
    │  - supplier_id       │                │
    │  - email             │                │
    │  - encrypted_password│                │
    │  - first_name        │                │
    │  - last_name         │                │
    │  - role (admin/rep)  │                │
    │  - active            │                │
    │  - invitation_token  │                │
    │  - Devise fields...  │                │
    └──────┬──────────────┘                │
           │                               │
           │ has_many                      │
    ┌──────▼──────────────────────────────▼──┐
    │   SupplierPortalAssignment              │
    │   (rep → customer mapping)              │
    │                                         │
    │  - supplier_user_id                     │
    │  - organization_id                      │
    └─────────────────────────────────────────┘

    ┌─────────────────────────────────────────┐
    │   SupplierPortalInvitation               │
    │                                          │
    │  - supplier_id                           │
    │  - email                                 │
    │  - role (admin/rep)                      │
    │  - token (unique)                        │
    │  - invited_by (polymorphic)              │
    │  - expires_at                            │
    │  - accepted_at                           │
    └─────────────────────────────────────────┘

    ┌─────────────────────────────────────────┐
    │   SupplierDailySnapshot                  │
    │   (pre-computed analytics, one per day)  │
    │                                          │
    │  - supplier_id                           │
    │  - snapshot_date                         │
    │  - total_orders                          │
    │  - total_revenue                         │
    │  - unique_customers                      │
    │  - avg_order_value                       │
    │  - active_products                       │
    │  - out_of_stock_products                 │
    │  - discontinued_products                 │
    │  - new_orders_today                      │
    │  - new_revenue_today                     │
    │  - top_products_json (jsonb)             │
    │  - top_customers_json (jsonb)            │
    └─────────────────────────────────────────┘
```

### Existing Models Used (Read-Only)

| Model | What the Portal Reads |
|-------|----------------------|
| **Supplier** | Supplier name, code — links SupplierUser to their data |
| **SupplierProduct** | Product catalog: name, SKU, price, pack size, stock status, discontinued |
| **Order** | Orders placed to this supplier: amounts, status, dates, customer, location |
| **OrderItem** | Line items: product, quantity, unit price, line total |
| **OrderList** | Shopping lists (for cart abandonment analysis) |
| **OrderListItem** | Items in shopping lists (for cart abandonment analysis) |
| **Product** | Canonical product — bridges OrderListItems to SupplierProducts |
| **Organization** | Customer restaurant groups: name |
| **Location** | Restaurant locations: name, address |

---

## 8. Privacy & Security

### Data Isolation Rules

| Rule | Enforcement |
|------|-------------|
| **Suppliers see only their own data** | Every query filters by `supplier_id = current_supplier.id` via a base controller method. There is no URL parameter or user input that can override this |
| **Only completed orders shown** | Queries filter `status IN ('submitted', 'confirmed')` — suppliers never see pending, failed, or cancelled orders |
| **No other supplier pricing** | No cross-supplier queries exist in the portal. A supplier cannot see what competitors charge |
| **No individual chef names** | Customer pages show Organization name and Location name only. The User who placed the order is never exposed |
| **Rep-level scoping** | Reps can only see data for their assigned customers (Organizations). Admins see all |
| **Read-only** | The portal has no write operations on orders, products, or customer data. The only writes are: profile updates, team management, and product inaccuracy flags |

### Authentication Isolation

| Aspect | Details |
|--------|---------|
| **Separate Devise model** | `SupplierUser` is completely independent of `User` — different table, different cookies, different sessions |
| **No cross-access** | A restaurant user cannot access `/supplier` routes. A supplier user cannot access restaurant or admin routes |
| **Invitation-only** | No self-registration. Prevents unauthorized supplier accounts |
| **Account lockout** | 5 failed login attempts = 1 hour lockout (same as restaurant users) |

---

## 9. User Flows

### 9.1 First Supplier Onboarding

```
SupplierHub admin (super_admin) → Admin panel → Supplier Users
  │
  ▼
  "Invite Supplier User" → Enter email, select supplier, set role = admin
  │
  ▼
  System sends invitation email with unique link
  │
  ▼
  Supplier rep clicks link → Set password + name → Account created
  │
  ▼
  Redirected to /supplier (dashboard) → sees their supplier's data
```

### 9.2 Supplier Admin Invites a Rep

```
Supplier portal → Team → "Invite Team Member"
  │
  ▼
  Enter email, select role (admin or rep)
  │
  ▼
  If rep: assign specific customers (organizations)
  │
  ▼
  System sends invitation email → rep accepts → sees only assigned customers
```

### 9.3 Daily Check-In (Account Manager)

```
Log in → Dashboard
  │
  ├─ Scan KPIs: any drops in revenue or order count? → drill into Analytics
  │
  ├─ Check "Recent Orders" for anything unusual
  │
  ├─ Navigate to Customers → sort by "Last Order"
  │    → Identify customers who haven't ordered recently
  │    → Plan outreach
  │
  ├─ Navigate to Cart Abandonment
  │    → See which products are being considered but not ordered
  │    → Plan follow-up: samples, pricing discussions, availability checks
  │
  └─ Navigate to Products → Health tab
       → Verify any flagged out-of-stock or discontinued items
       → Flag inaccuracies if data is wrong
```

### 9.4 Price Change Review (Category Manager)

```
Analytics → Products → Price Changes
  │
  ▼
  See list of products with recent price changes
  │
  ▼
  For each: before/after price, before/after order volume
  │
  ▼
  Identify products where a price increase caused significant volume drop
  │
  ▼
  Decide: adjust price back, accept lower volume, or run a promotion
```

---

## 10. Background Processing

### Daily Analytics Snapshot Job

To avoid slow page loads from real-time aggregation queries, a background job pre-computes key metrics daily.

| Aspect | Details |
|--------|---------|
| Job name | `SupplierSnapshotJob` |
| Schedule | Daily at 6:30 AM (after catalog import at 5 AM, before supplier reps start their day) |
| Queue | `low` priority (doesn't compete with scraping or critical jobs) |
| What it computes | Total orders, revenue, customer count, avg order value, product health counts, top 10 products, top 10 customers |
| Storage | `supplier_daily_snapshots` table — one row per supplier per day |
| Dashboard usage | Dashboard loads today's snapshot for instant KPIs. Falls back to real-time queries if no snapshot exists |
| Historical value | Snapshots accumulate over time, enabling month-over-month and year-over-year comparisons |

---

## 11. Navigation Structure

```
┌─────────────────────────────────────────────────────┐
│  SupplierHub  │ Dashboard │ Products │ Customers │  │
│  [Supplier]   │ Analytics │ Cart Insights │ Team  │  │
│               │                                     │
│                                    [Avatar ▾]       │
│                                    Settings         │
│                                    Sign Out         │
└─────────────────────────────────────────────────────┘
```

| Nav Item | URL | Access |
|----------|-----|--------|
| Dashboard | `/supplier` | All |
| Products | `/supplier/products` | All |
| Customers | `/supplier/customers` | All (reps: filtered to assigned) |
| Analytics | `/supplier/analytics` | All |
| Cart Insights | `/supplier/cart_insights` | All |
| Team | `/supplier/team_members` | Admins only |
| Settings | `/supplier/settings` | All |

---

## 12. Competitive Landscape

| Competitor | Supplier Analytics | Cart Abandonment | Connected to Real Orders | Price |
|------------|-------------------|------------------|-------------------------|-------|
| **BlueCart** | Basic (own marketplace only) | No | Own marketplace only | $300-500/mo |
| **Sysco Shop** | Internal only | No | Sysco orders only | N/A (internal) |
| **US Foods MO-Biz** | Internal only | No | US Foods orders only | N/A (internal) |
| **Arrowstream** | Supply chain analytics | No | EDI integration | Enterprise pricing |
| **SupplierHub** | **Cross-platform, multi-customer** | **Yes** | **Direct supplier portal orders** | **TBD** |

**Our advantage:** We're the only platform that gives suppliers visibility across *all* their SupplierHub customers in one place, including the unique cart abandonment data that no supplier has access to today. Their own portals only show what was ordered — we show what was *considered*.

---

## 13. Non-Functional Requirements

| Requirement | Specification |
|-------------|---------------|
| **Page load time** | Dashboard loads in < 2 seconds (using pre-computed snapshots) |
| **Query performance** | Analytics queries complete in < 3 seconds with composite indexes |
| **Data freshness** | Snapshots computed daily; real-time queries available as fallback |
| **Authentication** | Separate Devise scope — no session conflicts with restaurant users |
| **Concurrency** | Multiple supplier users can access the portal simultaneously |
| **Browser support** | Chrome, Safari, Firefox, Edge (latest 2 versions) |

---

## 14. Phasing & Timeline

| Phase | Scope | Duration | Dependencies |
|-------|-------|----------|-------------|
| **Phase 1 — Foundation** | Auth (SupplierUser model, Devise, invitation flow), Dashboard (KPIs, recent orders), Product Catalog (browse, search, filter, health page) | 3-4 weeks | None |
| **Phase 2 — Relationships** | Customer Rankings, Customer Detail (order trend, top products, locations), Revenue Analytics (weekly trends, by customer, by location, date filtering) | 2-3 weeks | Phase 1 |
| **Phase 3 — Intelligence** | Cart Abandonment, Product Performance (top/bottom sellers, trending), Price Change Impact analysis, Daily Snapshot job | 2-3 weeks | Phase 2 |
| **Phase 4 — Team & Polish** | Team Management (invite, assign customers, activate/deactivate), Settings, Mobile responsiveness, Dark mode | 2-3 weeks | Phase 1 |

**Total estimate:** 9-13 weeks

### Phase 1 Deliverables (MVP)
The MVP is intentionally narrow: **log in, see your numbers, check your products.** This is enough to demonstrate value to suppliers and validate the concept before investing in deeper analytics.

- Supplier user accounts with invitation-based onboarding
- Dashboard with 5 KPI cards + recent orders table
- Product catalog with search, filters, and health page
- Product inaccuracy flagging
- Admin interface to create initial supplier accounts

---

## 15. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **Suppliers don't adopt** — "we have our own tools" | Medium | High | Lead with unique data they can't get elsewhere (cart abandonment, cross-customer view). Offer free during beta |
| **Not enough order data** — platform is early, thin data | High (now) | Medium | Be transparent about data volume. Snapshots and trends become more valuable as order volume grows |
| **Privacy concerns from restaurants** — "you're sharing our data with suppliers?" | Medium | High | Suppliers only see aggregate data they already have (order history is in their own portal). We don't expose chef names, internal list names, or competitor pricing. Consider opt-out toggle |
| **Performance under scale** — analytics queries slow down | Low (now) | Medium | Daily snapshot job pre-computes heavy queries. Composite indexes on key tables. Monitor query times |
| **Scope creep into supplier-side ordering** — "can I push promotions?" | Medium | Medium | Explicitly out of scope. Portal is read-only analytics. Evaluate write features only after analytics adoption is proven |
| **Data accuracy questions** — suppliers dispute scraped data | Medium | Medium | Product inaccuracy flagging feature gives suppliers a voice. Builds trust and improves data quality |

---

## 16. Out of Scope (for now)

These are potentially valuable but intentionally deferred:

- **Supplier-initiated promotions** — pushing deals or pricing to restaurant users
- **Real-time order notifications** — push alerts when an order is placed (natural fit via ActionCable/Solid Cable, but deferred to prove core value first)
- **Invoice management** — uploading or reconciling invoices
- **Write access to product data** — letting suppliers update their own prices, descriptions, or stock status
- **API access** — programmatic access to analytics data
- **White-labeling** — custom branding per supplier
- **Mobile app** — native iOS/Android (responsive web is Phase 4)
- **Competitor benchmarking** — showing a supplier how they compare to others (too sensitive, likely never)

---

## 17. Success Criteria

| Metric | Phase 1 Target | Phase 3 Target |
|--------|---------------|----------------|
| Supplier accounts created | All 4 suppliers have at least 1 active user | 2+ users per supplier |
| Weekly active logins | 1+ login/week per supplier | 3+ logins/week per supplier |
| Product flags submitted | At least 5 inaccuracy reports in first month | Ongoing catalog improvement |
| Dashboard engagement | Average session > 2 minutes | Average session > 5 minutes |
| Cart abandonment insights viewed | — | At least 1 view/week per active user |
| Supplier satisfaction (qualitative) | "Useful" feedback from 3/4 suppliers | NPS 40+ |

---

## 18. Open Questions

1. **Restaurant opt-out** — Should restaurants be able to opt out of having their data visible to suppliers? The data (orders, organization names) is already visible to suppliers through their own portals — we're just aggregating it. But some restaurants may not want this. Recommendation: no opt-out for Phase 1, revisit if feedback warrants it.

2. **Free or paid** — Is the supplier portal free (to drive adoption and create platform stickiness) or a paid feature (revenue opportunity)? Recommendation: free during beta to prove value, then evaluate pricing after 3 months of usage data.

3. **Data history depth** — How far back should analytics go? All time? Last 12 months? Recommendation: all time for KPIs, last 90 days default for trends with date picker for custom ranges.

4. **Supplier self-registration** — Should supplier reps be able to sign up with an @usfoods.com email (domain verification) instead of requiring an invitation? Recommendation: invitation-only for Phase 1 (tighter control), evaluate domain-based registration later.

5. **Product data corrections** — When a supplier flags an inaccuracy, should they be able to suggest the correct value (not just flag it)? Recommendation: yes — include optional "suggested correction" fields (name, price, pack size) in the flag form.

6. **Cross-feature integration** — Should the inventory module (if built) surface data in the supplier portal? E.g., "this product is below par at 3 customer locations." Recommendation: evaluate after both features are live.
