# Product Requirements Document: Global Product Matching & Ordering Lists

**Feature Name**: Global Product Matching & Lightweight Ordering Lists
**Status**: Draft
**Date**: 2026-03-09

---

## 1. Executive Summary

SupplierHub currently requires users to create a "Comparison List" every time they want to match products across suppliers — selecting which supplier order guides to compare, waiting for AI matching, and reviewing results. If a new supplier is added, all that work starts over.

This refactor flips the model: **match all products from all suppliers once** at the location level, with a human confirming every match. Then let chefs create lightweight **Ordering Lists** — simple subsets of confirmed products — that they can reorder from with one click. No re-matching, no setup friction, no lost work when suppliers change.

**The key principle**: AI *proposes* matches, but a human always *confirms* them. This happens once during initial setup, and again only for new items when a supplier is added. Confirmed matches are never touched — they're permanent until a human changes them.

---

## 2. Problem Statement

Today's product matching workflow has several friction points:

1. **Matching is per-list** — every Comparison List requires selecting supplier order guides and running the matching process. Want a different subset of products? Create another list and match again.
2. **Adding a supplier resets everything** — when a new supplier credential is connected, existing confirmed matches can't be reused. The chef has to start over.
3. **No reusable ordering shortcuts** — there's no way to save a "Monday produce order" or "Weekly dry goods" as a quick-pick list that draws from already-matched products.
4. **Matching work is siloed** — one chef's confirmed matches aren't shared with other team members at the same location or across the organization.

| Problem | Impact |
|---------|--------|
| Re-matching for every list | Wastes time; chefs avoid creating focused lists |
| New supplier = start over | Discourages connecting additional suppliers |
| No quick-pick ordering lists | Chefs reorder from the full match list every time, scrolling past irrelevant items |
| No sharing of match work | Each user duplicates effort; inconsistent product names across team |

---

## 3. Proposed Solution

### Two-Layer Architecture

**Layer 1: Master Match List (one-time setup per location)**
- One per location (optionally shared across the entire organization)
- Automatically includes all supplier order guides synced for that location
- AI proposes matches; a chef reviews and confirms each one (one-time effort)
- When a new supplier is added: AI proposes matches for new items only → chef reviews just those
- Confirmed matches are permanent and never modified by the system
- This is the "source of truth" for cross-supplier product comparison

**Layer 2: Ordering Lists (user-created, lightweight)**
- Simple subsets of products from the Master Match List
- Created by picking products from the matched list and naming the list (e.g., "Monday Produce," "Prep List," "Weekend Brunch")
- Shared across the organization by default, with a private toggle for personal lists
- Each item references a matched product — prices and supplier options stay current automatically
- One-click ordering: open a list, set quantities, submit

### How It Works

```
INITIAL SETUP (one-time):
  Chef connects suppliers → order guides sync
  → AI proposes matches across all suppliers
  → Chef reviews & confirms each match (same as current workflow)
  → Done. This never needs to happen again for these products.

NEW SUPPLIER ADDED (rare):
  New supplier syncs → AI proposes matches for new items only
  → Chef reviews & confirms ONLY the new items
  → All previously confirmed matches: completely untouched

DAILY ORDERING (the new part):
  Chef creates "Monday Produce" list → picks items from confirmed matches
  Monday morning → opens "Monday Produce"
                → adjusts quantities
                → sees best prices across all suppliers
                → submits order
```

---

## 4. Target Users

| User | How They Use This | Key Needs |
|------|-------------------|-----------|
| **Head Chef** | Reviews the Master Match List, confirms/rejects matches, creates ordering lists for different days/purposes | Confidence that matches are correct; fast list creation |
| **Sous Chef / Line Cook** | Uses pre-made ordering lists to place orders | Just open a list, set quantities, submit — no matching knowledge needed |
| **Owner / Manager** | Reviews match coverage across suppliers, may create ordering lists for multiple locations | Org-wide visibility; shared lists across locations |

---

## 5. Business Objectives

| Objective | Metric | Target |
|-----------|--------|--------|
| Reduce ordering friction | Time from "I need to order" to order submitted | < 3 minutes with a saved list |
| Increase supplier connections | Chefs willing to connect more suppliers (no re-matching penalty) | 20% increase in multi-supplier orgs |
| Improve match quality | % of products with confirmed matches | 80% confirmed within 2 weeks of setup |
| Drive ordering list adoption | Ordering lists created per organization | 3+ lists per org within first month |
| Team collaboration | Shared lists used by multiple users | 50% of lists used by 2+ team members |

---

## 6. Feature Requirements

### Phase 1: Master Match List (Foundation)

> **Goal**: Every location has a single master match list where products are matched once (with human confirmation) and stay matched. New suppliers only require reviewing new items.

#### 6.1 Automatic Master List Creation

| Requirement | Details |
|-------------|---------|
| One per location | Each location gets a Master Match List created automatically when the first supplier list syncs |
| Auto-includes all supplier order guides | Every synced supplier order guide for the location is automatically attached — including multiple lists from the same supplier (e.g., US Foods "Proteins" + "Produce" + "Favorites") |
| Order guides only, not full catalog | Matching applies only to items from the chef's curated order guides (typically 50-200 items per supplier), NOT the full supplier catalog (which can be tens of thousands of items). The full catalog is only searched on-demand to fill gaps (existing `CatalogSearchService` behavior). |
| No manual setup | Chefs don't need to "create" a comparison list — it exists by default |
| Named automatically | Default name: "[Location Name] — All Products" |

#### 6.1.1 Deduplication

When a supplier has multiple order guides, the same product can appear in more than one list (e.g., "Chicken Breast" is in both the "Proteins" guide and the "Favorites" list). The master list must deduplicate so chefs aren't asked to match the same product twice.

| Requirement | Details |
|-------------|---------|
| Same-supplier dedup | If two SupplierListItems from the same supplier link to the same SupplierProduct, only one is included in matching. The chef sees the product once, not once per list it appears in. |
| Cross-supplier is matching | "Chicken Breast" from US Foods and "Chicken Breast" from Chef's Warehouse are different items that should be matched — that's the whole point. Only same-supplier duplicates are collapsed. |
| Dedup strategy | Use the existing `SupplierListItem → SupplierProduct` link as the dedup key. Multiple SupplierListItems pointing to the same SupplierProduct are treated as one item for matching purposes. |
| Price source | When deduped, use the most recently updated price across the duplicate items. |

#### 6.2 Incremental Matching (New Supplier Added)

Incremental matching only runs when a **new supplier** is connected or a new supplier order guide is synced. It does NOT re-match existing products on daily syncs — daily syncs only update prices.

| Requirement | Details |
|-------------|---------|
| Additive only | New supplier products are proposed as matches against existing confirmed matches — never deletes or modifies confirmed matches |
| Human review required | All proposed matches start as "auto-matched" and require chef confirmation before being treated as confirmed. **No match is finalized without human approval.** |
| Review notification | Chef is notified: "5 new products need review" when incremental matching proposes new matches |
| Triggered on new supplier data | Runs when a new supplier list is attached to the master list (not on every daily price sync) |
| Same matching quality | Uses the existing 4-pass strategy: shared product link → exact name → similarity score → AI matching |
| Matches against canonical names | New items are compared to existing `ProductMatch` canonical names, not re-compared across all items |
| Unmatched items preserved | Products that can't be matched get their own row with "unmatched" status for manual review |
| Full re-match available | "Re-match All" button available as a reset option if incremental matching isn't sufficient |

#### When Matching Runs vs. Doesn't

| Event | Matching Runs? | Human Review Needed? | Existing Matches Affected? |
|-------|---------------|---------------------|--------------------------|
| Initial setup (first time) | Yes — full AI matching | Yes — chef confirms all matches | N/A — no prior matches |
| New supplier connected | Yes — incremental, new items only | Yes — chef confirms new matches only | No — untouched |
| Chef adds items to an order guide | Yes — incremental, new items only | Yes — chef confirms new matches only | No — untouched |
| Chef creates a new order guide | Yes — incremental, new items only (deduped against existing) | Yes — chef confirms new matches only | No — untouched |
| Chef removes items from an order guide | **No** — existing matches stay valid | No | No — match and product data preserved |
| Daily supplier price sync | **No** — prices update on existing matches | No | No — prices update automatically |
| Product discontinued by supplier | **No** — handled by existing discontinuation logic | No | Match preserved; product flagged as unavailable |
| Chef clicks "Re-match All" | Yes — full reset | Yes — all matches need re-confirmation | Yes — intentional full reset |

#### 6.3 Organization Sharing Toggle

| Requirement | Details |
|-------------|---------|
| Default: location-scoped | Master Match List visible only to users at that location. Other locations create their own. |
| "Use for entire organization" toggle | When enabled, this master list becomes the shared source of truth for all locations. Other locations don't need to create their own — they use this one. |
| Owner-only permission | Only organization owners can toggle between "this location only" and "use for entire organization." Chefs and managers cannot change this setting to prevent accidental disruption to other locations. |
| Show all products, flag availability | When shared across locations, the master list includes the union of ALL suppliers across ALL locations. Products from suppliers not available at a given location are shown but flagged as "not available at [location]" — visible for reference but not orderable. This supports national organizations where a supplier may service the East Coast but not the West Coast. |
| Additive when shared | Sharing across org attaches supplier lists from other locations and triggers incremental matching for newly-included items (requires human review). |
| Easy to change | Toggle can be flipped at any time without losing match data. |

#### 6.4 Master Match List UI

| Requirement | Details |
|-------------|---------|
| Prominent placement | Master list appears at the top of the Order Guides / Comparison Lists page |
| Same comparison table | Reuses the existing product comparison UI (sticky product name column, supplier price columns, per-unit pricing) |
| Match status badges | Confirmed, Auto-Matched, Unmatched, Rejected — same as current |
| Confirm/reject/rename actions | Same workflow as current comparison list review |
| Category grouping | Products grouped by category for easier scanning |
| "Create Ordering List" button | Primary call-to-action on the master list page |

---

### Phase 2: Ordering Lists

> **Goal**: Chefs can create lightweight, reusable ordering lists from matched products and order from them with minimal friction.

#### 6.5 Creating an Ordering List

| Requirement | Details |
|-------------|---------|
| From confirmed matches only | Checkbox selection on the master list → "Create Ordering List" (only confirmed matches are selectable — unreviewed/auto-matched items must be confirmed first) |
| Name the list | Required field — e.g., "Monday Produce," "Weekend Brunch Prep" |
| Set default quantities | Optionally set quantities during creation (defaults to 1) |
| Quick creation | Select products, name it, done — no matching, no waiting |

#### 6.6 Ordering List Structure

| Requirement | Details |
|-------------|---------|
| References matched products | Each item points to a ProductMatch, not a raw product — prices and supplier options stay current |
| Per-item quantity | Default quantity saved with the list, adjustable at order time |
| Ordered/sortable | Drag-to-reorder or manual position |
| Duplicatable | "Duplicate List" to create variations (e.g., "Monday Produce" → "Thursday Produce") |
| Deletable | Remove items or delete entire list |

#### 6.7 Sharing & Visibility

Three visibility levels for ordering lists:

| Level | Who Can See & Use | Example Use Case |
|-------|-------------------|------------------|
| **Private** | Only the chef who created it | Personal prep list, experimental ordering |
| **This Location** (default) | All team members at the same restaurant | "Monday Produce" for the Main St kitchen |
| **Whole Organization** | All team members across all locations | "Standard Dry Goods" shared across all restaurants |

| Requirement | Details |
|-------------|---------|
| Default: location-scoped | New ordering lists default to "This Location" — visible to everyone at the same restaurant |
| Three-level selector | Dropdown or segmented control: Private / This Location / Whole Organization |
| Any user can change | The creator (or any team member with edit access) can adjust the visibility level |
| Visual indicator | Badge on each list: lock icon (Private), pin icon (This Location), globe icon (Whole Organization) |
| Shared list editing | Location and org-visible lists can be edited by any team member who can see them |

#### 6.8 Ordering from a List

| Requirement | Details |
|-------------|---------|
| Order builder UI | Same supplier price comparison columns, quantity inputs, and KPI bar as the current order builder |
| Pre-filled quantities | List's saved quantities pre-populate the order form |
| Supplier selection | Click a supplier's price cell to override the default (cheapest) selection |
| Delivery date | Required before submission |
| Submit → pending orders | Same flow: creates pending orders grouped by supplier → review → submit batch |

---

### Phase 3: Migration & Cleanup

> **Goal**: Existing data is preserved and the old manual comparison workflow is retired or de-emphasized.

#### 6.9 Data Migration

| Requirement | Details |
|-------------|---------|
| Preserve AggregatedList #8 | The existing production comparison list with confirmed matches becomes the master list for its location |
| No data loss | All confirmed/auto-matched ProductMatch records are preserved |
| Old lists deprecated | Other comparison lists that haven't been used are cleaned up or archived |

#### 6.10 UI Transition

| Requirement | Details |
|-------------|---------|
| Master list is primary | The Master Match List replaces "New Comparison List" as the primary action |
| Custom comparisons available | Keep the ability to create custom comparison lists for ad-hoc analysis (secondary/advanced) |
| Navigation update | "Order Guides" page leads with the master list, then ordering lists, then custom comparisons |

---

## 7. Data Model Changes

### Modified Tables

```
aggregated_lists (existing)
  + list_type:          string    ("master" or "custom", default: "custom")
  + auto_sync:          boolean   (default: false)
  + shared_across_org:  boolean   (default: false)

  Unique index: [organization_id, list_type, location_id]
                WHERE list_type = 'master'

order_list_items (existing)
  + product_match_id:   bigint    (nullable FK → product_matches, on_delete: nullify)
  ~ product_id:         becomes nullable (match-backed items don't need a canonical product)

order_lists (existing)
  + visibility:         string    ("private", "location", "organization"; default: "location")

product_matches (existing)
  + category:           string    (denormalized for grouping/filtering)
```

### No New Tables Required

The refactor reuses existing models (`AggregatedList`, `ProductMatch`, `OrderList`, `OrderListItem`) with minimal schema additions. This keeps the migration simple and preserves all existing functionality.

### Relationship Diagram (New Flow)

```
Organization
└── Location
    └── Master AggregatedList (list_type: 'master', auto_sync: true)
        ├── AggregatedListMappings → all SupplierLists for this location
        └── ProductMatches (the single source of truth)
            └── ProductMatchItems (one per supplier per match)

Organization
└── OrderLists (is_private: false = shared, true = private)
    └── OrderListItems
        └── product_match_id → ProductMatch (from the master list)
```

---

## 8. User Flows

### 8.1 Automatic Setup (No User Action Required)

```
Chef connects a supplier credential
  → Supplier list sync runs (daily cron or manual)
  → System auto-creates Master Match List for the location (if not exists)
  → System auto-attaches the synced SupplierList
  → Incremental matching runs in background
  → Chef sees "Your products are being matched..." notification
  → Matching completes → products ready for review
```

### 8.2 Review Matches (Same as Current)

```
Navigate to Master Match List (prominent card on Order Guides page)
  │
  ▼
  Product comparison table
  ┌─────────────────────────────────────────────────────────┐
  │  Product          │ US Foods  │ Chef's WH │ PPO        │
  │───────────────────│───────────│───────────│────────────│
  │  Roma Tomatoes    │ $32.50   │ $34.00    │ $29.99 ✓  │
  │  ✓ Confirmed      │ 25lb case │ 25lb case │ 25lb case  │
  │                   │           │           │            │
  │  Olive Oil EVOO   │ $18.00 ✓ │ —         │ $19.50     │
  │  ⚡ Auto-matched  │ 1 gal    │           │ 1 gal      │
  │                   │           │           │            │
  │  Wagyu Strips     │ —        │ $89.00    │ —          │
  │  ○ Unmatched      │           │           │            │
  └─────────────────────────────────────────────────────────┘
  │
  ├── Confirm / Reject / Rename as needed
  │
  └── [Create Ordering List] button
```

### 8.3 Create an Ordering List

```
Click "Create Ordering List" on Master Match List
  │
  ▼
  ☑ Select products to include (checkboxes on each row)
  [Select All] [Select Category: Produce ▾] [Select by Supplier ▾]
  │
  ▼
  Name your list: [Monday Produce Order          ]
  Sharing:        [● Shared with organization  ○ Private]
  │
  ▼
  "Create List" → redirects to the new ordering list
```

### 8.4 Place an Order from an Ordering List

```
Navigate to "My Ordering Lists"
  │
  ▼
  ┌────────────────────────────────────────────┐
  │  Monday Produce    │ 12 items │ Last used: Mar 3 │
  │  Weekend Brunch    │  8 items │ Last used: Feb 28 │
  │  Emergency Restock │  5 items │ Last used: Mar 7  │
  └────────────────────────────────────────────┘
  │
  │ Click "Monday Produce"
  ▼
  Order builder UI (same as current)
  - Pre-filled quantities from saved defaults
  - Supplier price comparison columns
  - Edit quantities, select suppliers
  - Set delivery date
  │
  ▼
  "Submit Order" → pending orders created → review → batch submit
```

### 8.5 New Supplier Added (Additive, Requires Review)

```
Chef connects a new supplier (e.g., What Chefs Want)
  │
  ▼
  Supplier list syncs → new SupplierList created
  │
  ▼
  System auto-attaches to Master Match List
  │
  ▼
  Incremental matching PROPOSES matches:
  - "Chicken Breast" from WCW → proposed match to existing "Chicken Breast"
    → status: "auto_matched" (needs chef confirmation)
  - "Specialty Sauce XYZ" from WCW → no match found
    → status: "unmatched" (needs chef review)
  │
  ▼
  Chef is notified: "4 new products need review"
  │
  ▼
  Chef opens Master Match List → reviews only the new items:
  - Confirms "Chicken Breast" match → now 3 suppliers for this product ✓
  - Manually matches "Specialty Sauce XYZ" or leaves unmatched
  │
  All previously confirmed matches: completely untouched ✓
  Time spent: ~2 minutes (vs. re-matching everything from scratch)
```

---

## 9. Sharing Model

### Master Match List

| Setting | Behavior |
|---------|----------|
| **"This location only"** (default) | Only users at this location see and use the master list. Other locations create their own master list. |
| **"Use for entire organization"** (owner-only toggle) | This master list becomes the org-wide source of truth. All locations see it and can create ordering lists from it. Products from all locations' suppliers are included, with availability flagged per location. |

**Who can toggle**: Only organization owners. This prevents a chef at one location from accidentally making their list the org master and disrupting other locations.

**Multi-supplier, multi-location behavior**: When shared org-wide, the master list is the union of all suppliers across all locations. A product from a supplier that only services the East Coast will show up for West Coast locations too — but flagged as "not available at [location]" so chefs know they can't order it there. This gives full visibility into what's available nationally while keeping ordering accurate per-location.

### Ordering Lists

| Setting | Behavior |
|---------|----------|
| **Private** | Only the creator can see and use. For personal prep lists or experiments. |
| **This Location** (default) | Visible to all team members at the same restaurant. Standard for day-to-day ordering lists. |
| **Whole Organization** | Visible to all team members across all locations. For standardized lists shared nationally (e.g., "Corporate Approved Dry Goods"). |

---

## 10. Non-Functional Requirements

| Requirement | Specification |
|-------------|---------------|
| Incremental matching speed | < 30 seconds for 50 new items against 200 existing matches |
| Master list page load | < 2 seconds for 300 matched products |
| Ordering list creation | Instant — no background job, no matching needed |
| Backward compatibility | Existing comparison lists continue to work; no data loss during migration |
| Concurrency safety | Only one matching job per master list at a time (job-level lock) |

---

## 11. Phasing & Milestones

| Phase | Scope | Goal |
|-------|-------|------|
| **Phase 1 — Foundation** | Schema migration, master list model, incremental matching service, auto-attach on sync | Matching happens automatically; master list exists per location |
| **Phase 2 — Ordering Lists** | Create from matches, shared/private toggle, order builder from ordering lists | Chefs can create and order from lightweight lists |
| **Phase 3 — Migration & Polish** | Promote AggregatedList #8, UI prominence, deprecate manual comparison creation | Clean transition; master list is the primary workflow |

### Dependencies

| Phase | Depends On |
|-------|-----------|
| Phase 1 | None — additive schema changes and new service |
| Phase 2 | Phase 1 — ordering lists reference ProductMatches from master list |
| Phase 3 | Phase 2 — full workflow must be functional before retiring old flow |

---

## 12. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Incremental matching produces lower quality than full re-match | Medium | Medium | Keep "Re-match All" as a recovery option; track match quality metrics |
| Master list grows very large (500+ products) | Medium | Low | Category grouping, pagination, status filters (confirmed / needs review) |
| Ordering lists become stale if products are discontinued | Low | Medium | Show "unavailable" badge on discontinued items; prompt to remove |
| Migration breaks existing AggregatedList #8 data | Low | High | Migration is additive (sets `list_type = 'master'`); no data deleted |
| Team members accidentally edit shared ordering lists | Medium | Low | Show "last edited by [name]" on lists; consider edit history later |

---

## 13. Out of Scope (for now)

- **Template ordering lists** — system-suggested lists based on ordering patterns ("You order these 10 items every Monday")
- **Scheduled/recurring orders** — auto-submit an ordering list on a schedule
- **Cross-org list sharing** — sharing ordering lists between different organizations
- **Ordering list analytics** — which lists are used most, cost trends per list
- **Inventory integration** — connecting ordering lists to par levels and auto-ordering (covered in Inventory Module PRD)

---

## 14. Success Criteria

| Metric | Phase 1 Target | Phase 2 Target |
|--------|---------------|----------------|
| Master list auto-creation | 100% of locations with synced suppliers have a master list | — |
| Match preservation rate | 100% of existing confirmed matches survive new supplier additions | — |
| Incremental match accuracy | 85%+ of auto-matched items confirmed by user | — |
| Ordering lists created | — | 3+ per organization within first month |
| Order time reduction | — | < 3 minutes from opening a saved list to order submission |
| Shared list adoption | — | 50%+ of lists used by 2+ team members |

---

## 15. Open Questions

1. **Category management** — Should chefs be able to create custom categories for organizing matched products, or stick with supplier-provided categories?

2. **Ordering list templates** — Should we offer starter templates (e.g., "Produce," "Proteins," "Dry Goods") or let chefs build from scratch?

3. **Notification preferences** — When incremental matching runs and finds new matches or unmatched products, how should the chef be notified? In-app badge? Email?

4. **Multi-location ordering** — If a master list is shared across the org, can a chef at Location A create an order that gets placed through Location B's supplier account?

5. **Ordering list versioning** — Should we track changes to ordering lists over time (items added/removed) or keep it simple with current state only?
