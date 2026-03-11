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

**Layer 1: Matched Lists (chef-created, per location)**
- Chefs create matched lists for their location by selecting which supplier order guides to include
- AI proposes matches across the selected suppliers; the chef reviews and confirms each one
- Each location can have multiple matched lists (e.g., one chef might create "All Suppliers" while another creates "Produce Only")
- Confirmed matches are permanent and never modified by the system
- An owner can optionally **promote** any location's matched list to be the org-wide standard — but this is rare, especially when locations have different suppliers or pricing
- If no org-wide list is promoted, each location simply uses its own matched lists (the common case)

**Layer 2: Ordering Lists (user-created, lightweight)**
- Simple subsets of products from a matched list
- Created by picking products from the matched list and naming the list (e.g., "Monday Produce," "Prep List," "Weekend Brunch")
- Shared at the location level by default, with private and org-wide options
- Each item references a matched product — prices and supplier options stay current automatically
- One-click ordering: open a list, set quantities, submit

### Navigation: "Supplier Data" Dropdown

A key lesson from the first implementation: separate navigation items for Supplier Credentials, Matched Lists, and Order Lists created clutter. The updated navigation consolidates related items:

```
┌─────────────────────────────┐
│  Supplier Data ▾            │  ← single dropdown
│  ├── Supplier Credentials   │  ← connect/manage logins
│  └── Matched Lists          │  ← view/create matched lists
│                             │
│  Order Lists                │  ← separate top-level nav item
└─────────────────────────────┘
```

**Supplier Data** groups the setup/configuration layer (credentials + matching) together because they're closely related — you connect a supplier, then match its products. **Order Lists** stays top-level because it's the daily workflow chefs use most.

### How It Works

```
SETUP (per location):
  Chef connects suppliers → order guides sync
  → Chef creates a Matched List, selecting which supplier guides to include
  → AI proposes matches across selected suppliers
  → Chef reviews & confirms each match (same as current workflow)
  → Done. This never needs to happen again for these products.

NEW SUPPLIER ADDED (rare):
  New supplier syncs → chef adds new guide to existing matched list
  → AI proposes matches for new items only
  → Chef reviews & confirms ONLY the new items
  → All previously confirmed matches: completely untouched

DAILY ORDERING (the main workflow):
  Chef creates "Monday Produce" list → picks items from confirmed matches
  Monday morning → opens "Monday Produce"
                → adjusts quantities
                → sees best prices across all suppliers
                → submits order

OPTIONAL ORG-WIDE PROMOTION (rare):
  Owner views a location's matched list
  → Promotes it as the org-wide standard
  → Other locations can reference it, but products from unavailable
     suppliers are flagged "not available at [location]"
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

### Phase 1: Matched Lists (Foundation)

> **Goal**: Chefs can create matched lists for their location, selecting which supplier order guides to include. Matching happens once with human confirmation. New suppliers only require reviewing new items. Owners can optionally promote a location's list to org-wide.

#### 6.1 Chef-Created Matched Lists

| Requirement | Details |
|-------------|---------|
| Chef-initiated | Chefs create matched lists by choosing a name and selecting which supplier order guides to include. This is an intentional action, not automatic. |
| Location-scoped by default | Each matched list belongs to the location where it was created. Other locations create their own. |
| Multiple lists per location | A location can have more than one matched list (e.g., "All Suppliers" vs. "Produce Only"), though most locations will just have one. |
| Supplier guide selection | During creation, the chef picks which synced supplier order guides to include — including multiple lists from the same supplier (e.g., US Foods "Proteins" + "Produce" + "Favorites"). Guides can be added later. |
| Order guides only, not full catalog | Matching applies only to items from the chef's curated order guides (typically 50-200 items per supplier), NOT the full supplier catalog (which can be tens of thousands of items). The full catalog is only searched on-demand to fill gaps (existing `CatalogSearchService` behavior). |
| Named by chef | Chef provides a descriptive name (e.g., "All Products," "Produce Comparison," "Weekend Menu Items") |

#### 6.1.1 Deduplication

When a matched list includes multiple order guides from the same supplier, the same product can appear in more than one (e.g., "Chicken Breast" is in both the "Proteins" guide and the "Favorites" list). The matched list must deduplicate so chefs aren't asked to match the same product twice.

| Requirement | Details |
|-------------|---------|
| Same-supplier dedup | If two SupplierListItems from the same supplier link to the same SupplierProduct, only one is included in matching. The chef sees the product once, not once per list it appears in. |
| Cross-supplier is matching | "Chicken Breast" from US Foods and "Chicken Breast" from Chef's Warehouse are different items that should be matched — that's the whole point. Only same-supplier duplicates are collapsed. |
| Dedup strategy | Use the existing `SupplierListItem → SupplierProduct` link as the dedup key. Multiple SupplierListItems pointing to the same SupplierProduct are treated as one item for matching purposes. |
| Price source | When deduped, use the most recently updated price across the duplicate items. |

#### 6.2 Incremental Matching (New Supplier Guide Added)

Incremental matching runs when a chef **adds a new supplier order guide** to an existing matched list. It does NOT re-match existing products on daily syncs — daily syncs only update prices.

| Requirement | Details |
|-------------|---------|
| Additive only | New supplier products are proposed as matches against existing confirmed matches — never deletes or modifies confirmed matches |
| Human review required | All proposed matches start as "auto-matched" and require chef confirmation before being treated as confirmed. **No match is finalized without human approval.** |
| Review notification | Chef is notified: "5 new products need review" when incremental matching proposes new matches |
| Triggered on guide addition | Runs when a chef adds a new supplier order guide to the matched list (not on every daily price sync) |
| Same matching quality | Uses the existing 4-pass strategy: shared product link → exact name → similarity score → AI matching |
| Matches against canonical names | New items are compared to existing `ProductMatch` canonical names, not re-compared across all items |
| Unmatched items preserved | Products that can't be matched get their own row with "unmatched" status for manual review |
| Full re-match available | "Re-match All" button available as a reset option if incremental matching isn't sufficient |

#### When Matching Runs vs. Doesn't

| Event | Matching Runs? | Human Review Needed? | Existing Matches Affected? |
|-------|---------------|---------------------|--------------------------|
| Chef creates matched list with guides | Yes — full AI matching | Yes — chef confirms all matches | N/A — no prior matches |
| Chef adds a new guide to existing list | Yes — incremental, new items only | Yes — chef confirms new matches only | No — untouched |
| Chef adds items to a supplier order guide | Yes — incremental, new items only | Yes — chef confirms new matches only | No — untouched |
| Chef removes items from an order guide | **No** — existing matches stay valid | No | No — match and product data preserved |
| Daily supplier price sync | **No** — prices update on existing matches | No | No — prices update automatically |
| Product discontinued by supplier | **No** — handled by existing discontinuation logic | No | Match preserved; product flagged as unavailable |
| Chef clicks "Re-match All" | Yes — full reset | Yes — all matches need re-confirmation | Yes — intentional full reset |

#### 6.3 Organization Promotion (Owner-Only)

Owners can promote any location's matched list to be the org-wide standard. This is optional and rare — most organizations won't use it, especially when locations have different suppliers or pricing.

| Requirement | Details |
|-------------|---------|
| Default: location-scoped | Matched lists are visible only to users at the location that created them. Each location manages its own. |
| Owner promotes a list | An owner can select any location's matched list and promote it as the org-wide standard. This is a deliberate action, not a toggle — the owner is saying "this list represents our organization's product catalog." |
| Owner-only permission | Only organization owners can promote or demote an org-wide list. Chefs and managers cannot change this setting to prevent accidental disruption to other locations. |
| Org-wide list overrides | When an org-wide list exists, it becomes the source of truth for all locations. Location-level lists still exist but the org list takes precedence for creating ordering lists. |
| Flag unavailable suppliers | Products from suppliers not available at a given location are shown but flagged as "not available at [location]" — visible for reference but not orderable. This supports national organizations where a supplier may service the East Coast but not the West Coast. |
| Demotable | The owner can demote the org-wide list back to location-only at any time without losing match data. Locations revert to using their own lists. |

#### 6.4 Matched List UI

| Requirement | Details |
|-------------|---------|
| Located under "Supplier Data" | Matched lists appear in the Supplier Data dropdown alongside Supplier Credentials |
| Same comparison table | Reuses the existing product comparison UI (sticky product name column, supplier price columns, per-unit pricing) |
| Match status badges | Confirmed, Auto-Matched, Unmatched, Rejected — same as current |
| Confirm/reject/rename actions | Same workflow as current comparison list review |
| Category grouping | Products grouped by category for easier scanning |
| "Create Ordering List" button | Primary call-to-action on the matched list page |
| Org-wide badge | If the list has been promoted to org-wide, show a prominent badge so all users know |

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

An ordering list is a **prioritized subset** of the matched list, not a filter. When placing an order, the chef sees their selected items prominently at the top, with the full matched list available below for one-off additions.

| Requirement | Details |
|-------------|---------|
| Two-section layout | **"Your List" section** (top): the items the chef selected when creating the ordering list — these are the items they order regularly. **"All Other Products" section** (below): every other confirmed product from the matched list, available for one-off additions without needing to edit the list. |
| Visual separation | Clear divider or heading between the two sections (e.g., "── Monday Produce (12 items) ──" then "── All Other Products (184 items) ──") |
| Order builder UI | Same supplier price comparison columns, quantity inputs, and KPI bar as the current order builder — applies to both sections |
| Pre-filled quantities | List items have saved default quantities pre-populated. "All Other Products" default to 0 (or blank). |
| One-off additions | Chef can set a quantity on any item in "All Other Products" to include it in this order — without permanently adding it to the ordering list |
| "Add to List" option | Optional: if a chef repeatedly orders a one-off item, they can click "Add to List" to permanently include it in the ordering list for next time |
| Supplier selection | Click a supplier's price cell to override the default (cheapest) selection |
| Delivery date | Required before submission |
| Submit → pending orders | Same flow: creates pending orders grouped by supplier → review → submit batch. Items from both sections are included if they have a quantity > 0. |

---

### Phase 3: Migration & Cleanup

> **Goal**: Existing data is preserved, navigation is consolidated under "Supplier Data," and the old manual comparison workflow is retired or de-emphasized.

#### 6.9 Data Migration

| Requirement | Details |
|-------------|---------|
| Preserve AggregatedList #8 | The existing production comparison list with confirmed matches is converted to a matched list (`list_type: 'matched'`) for its location |
| No data loss | All confirmed/auto-matched ProductMatch records are preserved |
| Old lists deprecated | Other comparison lists that haven't been used are cleaned up or archived |

#### 6.10 UI & Navigation Transition

| Requirement | Details |
|-------------|---------|
| "Supplier Data" dropdown | New navigation dropdown containing: Supplier Credentials + Matched Lists |
| "Order Lists" top-level | Ordering lists get their own top-level nav item (the daily workflow) |
| Matched lists are primary | Under Supplier Data, matched lists replace "New Comparison List" as the primary action |
| Custom comparisons available | Keep the ability to create custom comparison lists for ad-hoc analysis (secondary/advanced) |
| Remove old nav items | Remove separate "Supplier Credentials" and "Comparison Lists" nav items — both are now under "Supplier Data" |

---

## 7. Data Model Changes

### Modified Tables

```
aggregated_lists (existing)
  + list_type:          string    ("matched" or "custom", default: "custom")
  + promoted_org_wide:  boolean   (default: false)

  Note: "matched" type = chef-created matched lists (this feature)
        "custom"  type = ad-hoc comparison lists (existing behavior)

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
    └── AggregatedList (list_type: 'matched', created by chef)
        ├── AggregatedListMappings → selected SupplierLists
        └── ProductMatches (source of truth for this list)
            └── ProductMatchItems (one per supplier per match)

Organization (optional — owner promotes a location's matched list)
└── AggregatedList (list_type: 'matched', promoted_org_wide: true)
    └── Same structure, but visible to all locations
        └── Products from unavailable suppliers flagged per-location

Organization
└── OrderLists (visibility: private | location | organization)
    └── OrderListItems
        └── product_match_id → ProductMatch (from a matched list)
```

---

## 8. User Flows

### 8.1 Create a Matched List (Chef-Initiated)

```
Chef navigates to Supplier Data → Matched Lists
  │
  ▼
  Clicks "New Matched List"
  │
  ▼
  ┌─────────────────────────────────────────────────┐
  │  Name: [All Suppliers - Main St Kitchen        ] │
  │                                                  │
  │  Select supplier order guides to include:        │
  │  ☑ US Foods — Proteins (45 items)               │
  │  ☑ US Foods — Produce (32 items)                │
  │  ☑ US Foods — Favorites (18 items)              │
  │  ☑ Chef's Warehouse — Order Guide (22 items)    │
  │  ☑ PPO — Order Guide (28 items)                 │
  │  ☑ What Chefs Want — Full List (51 items)       │
  │                                                  │
  │  [Create & Start Matching]                       │
  └─────────────────────────────────────────────────┘
  │
  ▼
  AI matching runs in background
  → Chef sees "Matching 196 products across 4 suppliers..."
  → Matching completes → products ready for review
```

### 8.2 Review Matches (Same as Current)

```
Navigate to Supplier Data → Matched Lists → "All Suppliers - Main St Kitchen"
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
Click "Create Ordering List" on a matched list
  │
  ▼
  ☑ Select products to include (checkboxes on each row)
  [Select All] [Select Category: Produce ▾] [Select by Supplier ▾]
  │
  ▼
  Name your list: [Monday Produce Order          ]
  Sharing:        [● This Location  ○ Private  ○ Whole Organization]
  │
  ▼
  "Create List" → redirects to the new ordering list
```

### 8.4 Place an Order from an Ordering List

```
Navigate to Order Lists (top-level nav)
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
  ┌─────────────────────────────────────────────────────────────┐
  │  ── Monday Produce (12 items) ──────────────────────────── │
  │                                                             │
  │  Product        │ Qty │ US Foods │ Chef's WH │ PPO         │
  │  Carrots 50lb   │ [2] │ $28.50  │ $31.00    │ $26.99 ✓   │
  │  Roma Tomatoes  │ [3] │ $32.50  │ $34.00    │ $29.99 ✓   │
  │  Yellow Onions  │ [1] │ $18.00 ✓│ —         │ $19.50      │
  │  ...8 more items                                            │
  │                                                             │
  │  ── All Other Products (184 items) ────────────────────── │
  │                                                             │
  │  Product        │ Qty │ US Foods │ Chef's WH │ PPO         │
  │  Wagyu Strips   │ [ ] │ —       │ $89.00    │ —           │
  │  Olive Oil EVOO │ [ ] │ $18.00  │ —         │ $19.50      │
  │  ...                                                        │
  └─────────────────────────────────────────────────────────────┘
  │
  │ Chef adjusts quantities in "Your List" section
  │ Optionally adds qty to a one-off item from "All Other Products"
  │ Sets delivery date
  ▼
  "Submit Order" → pending orders created → review → batch submit
  (includes items from both sections where qty > 0)
```

### 8.5 Add New Supplier Guide to Matched List (Additive, Requires Review)

```
Chef connects a new supplier (e.g., What Chefs Want)
  → Supplier list syncs → new SupplierList created
  │
  ▼
  Chef opens their matched list → clicks "Add Supplier Guide"
  → Selects "What Chefs Want — Full List"
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
  Chef reviews only the new items:
  - Confirms "Chicken Breast" match → now 3 suppliers for this product ✓
  - Manually matches "Specialty Sauce XYZ" or leaves unmatched
  │
  All previously confirmed matches: completely untouched ✓
  Time spent: ~2 minutes (vs. re-matching everything from scratch)
```

### 8.6 Owner Promotes a Matched List to Org-Wide (Optional)

```
Owner navigates to Supplier Data → Matched Lists
  │
  ▼
  Sees matched lists across all locations:
  ┌──────────────────────────────────────────────────────┐
  │  All Suppliers - Main St    │ 196 products │ 4 suppliers │
  │  Produce Only - Downtown    │  45 products │ 2 suppliers │
  │  All Suppliers - Brooklyn   │ 112 products │ 3 suppliers │
  └──────────────────────────────────────────────────────┘
  │
  │ Clicks "Promote to Org-Wide" on "All Suppliers - Main St"
  ▼
  Confirmation: "This will make Main St's matched list the standard
  for all locations. Products from suppliers not available at other
  locations will be flagged. Continue?"
  │
  ▼
  List now shows 🌐 org-wide badge
  Other locations see it and can create ordering lists from it
  Products from unavailable suppliers flagged per-location
```

---

## 9. Sharing Model

### Matched Lists

| State | Behavior |
|-------|----------|
| **Location-scoped** (default) | The matched list belongs to the location where it was created. Only users at that location see and use it. Each location creates its own matched lists. |
| **Promoted to org-wide** (owner action) | An owner selects a location's matched list and promotes it as the org-wide standard. All locations can see it and create ordering lists from it. Products from suppliers not available at a given location are flagged as "not available at [location]." |

**Who can promote**: Only organization owners. Chefs and managers cannot promote a list — this prevents accidental disruption to other locations.

**When promotion makes sense**: Organizations with standardized menus across locations, or where one location has done thorough matching work that other locations can benefit from.

**When it doesn't**: Organizations where locations have completely different suppliers (e.g., California vs. New York), different menus, or different price structures. In these cases, each location just uses its own matched lists — which is the common and expected case.

**Multi-location behavior**: When a list is promoted to org-wide, products from suppliers that only service certain regions are shown but flagged as "not available at [location]." This gives visibility into what's available nationally while keeping ordering accurate per-location.

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
| Matched list page load | < 2 seconds for 300 matched products |
| Ordering list creation | Instant — no background job, no matching needed |
| Backward compatibility | Existing comparison lists continue to work; no data loss during migration |
| Concurrency safety | Only one matching job per matched list at a time (job-level lock) |

---

## 11. Phasing & Milestones

| Phase | Scope | Goal |
|-------|-------|------|
| **Phase 1 — Foundation** | Schema migration, matched list model, incremental matching service, "Supplier Data" nav dropdown | Chefs can create matched lists for their location; navigation is consolidated |
| **Phase 2 — Ordering Lists** | Create from matches, visibility toggle (private/location/org), order builder from ordering lists | Chefs can create and order from lightweight lists |
| **Phase 3 — Migration & Polish** | Convert AggregatedList #8, org-wide promotion, deprecate manual comparison creation | Clean transition; matched lists + ordering lists are the primary workflow |

### Dependencies

| Phase | Depends On |
|-------|-----------|
| Phase 1 | None — additive schema changes, new service, and nav restructure |
| Phase 2 | Phase 1 — ordering lists reference ProductMatches from matched lists |
| Phase 3 | Phase 2 — full workflow must be functional before retiring old flow |

---

## 12. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Incremental matching produces lower quality than full re-match | Medium | Medium | Keep "Re-match All" as a recovery option; track match quality metrics |
| Matched list grows very large (500+ products) | Medium | Low | Category grouping, pagination, status filters (confirmed / needs review) |
| Ordering lists become stale if products are discontinued | Low | Medium | Show "unavailable" badge on discontinued items; prompt to remove |
| Migration breaks existing AggregatedList #8 data | Low | High | Migration is additive (sets `list_type = 'matched'`); no data deleted |
| Team members accidentally edit shared ordering lists | Medium | Low | Show "last edited by [name]" on lists; consider edit history later |
| Navigation consolidation confuses existing users | Low | Medium | "Supplier Data" label is intuitive; credentials and matching are closely related setup tasks |

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
| Matched list creation | 100% of locations with synced suppliers create a matched list within first week | — |
| Match preservation rate | 100% of existing confirmed matches survive when new supplier guides are added | — |
| Incremental match accuracy | 85%+ of auto-matched items confirmed by user | — |
| Ordering lists created | — | 3+ per organization within first month |
| Order time reduction | — | < 3 minutes from opening a saved list to order submission |
| Shared list adoption | — | 50%+ of lists used by 2+ team members |

---

## 15. Open Questions

1. **Category management** — Should chefs be able to create custom categories for organizing matched products, or stick with supplier-provided categories?

2. **Ordering list templates** — Should we offer starter templates (e.g., "Produce," "Proteins," "Dry Goods") or let chefs build from scratch?

3. **Notification preferences** — When incremental matching runs and finds new matches or unmatched products, how should the chef be notified? In-app badge? Email?

4. **Multi-location ordering** — If a matched list is promoted org-wide, can a chef at Location A create an order that gets placed through Location B's supplier account?

5. **Ordering list versioning** — Should we track changes to ordering lists over time (items added/removed) or keep it simple with current state only?
