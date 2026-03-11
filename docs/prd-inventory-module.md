# Product Requirements Document: Restaurant Inventory Module

**Feature Name**: Restaurant Inventory Management
**Status**: Draft
**Branch**: `inventory-module` (experimental)
**Date**: 2026-03-05

---

## 1. Executive Summary

SupplierHub currently helps restaurants order from multiple suppliers in one place. The Inventory Module extends the platform backward in the workflow — from *"what do I need to order?"* to *"what do I have on hand right now?"*

Chefs will be able to count stock on their phone, set par levels for every item, and generate orders automatically when stock drops below par. The module connects directly to the existing ordering workflow: count stock → see what's low → build an order → place it through SupplierHub.

This closes the loop between **inventory → ordering → receiving** and makes SupplierHub the single tool a kitchen uses to manage its supply chain.

---

## 2. Problem Statement

Restaurant kitchens currently track inventory using one (or more) of:

1. **Clipboard and pen** — chef walks the walk-in, writes counts on paper, later transcribes into a spreadsheet or just mentally calculates what to order
2. **Spreadsheets** — a shared Google Sheet or Excel file that's perpetually out of date, rarely matches reality
3. **Memory** — experienced chefs "just know" what they need, but this knowledge walks out the door when they leave
4. **Expensive standalone systems** — dedicated inventory platforms (BlueCart, MarketMan, Craftable) that cost $300-800/month and don't connect to the restaurant's actual supplier ordering

The result:

| Problem | Impact |
|---------|--------|
| Over-ordering | Food waste, tied-up cash, storage overflow |
| Under-ordering | 86'd menu items, emergency orders at premium prices, lost revenue |
| No visibility for owners | Can't see stock levels or waste across locations without calling the kitchen |
| Disconnected from ordering | Even if a chef knows they're low, they still have to manually build an order in a separate system |
| Time-consuming counts | Full inventory takes 1-2 hours on paper; chefs skip it because it's tedious |

---

## 3. Proposed Solution

A mobile-first inventory system built into SupplierHub that:

- Mirrors the physical kitchen layout (walk-in, dry storage, freezer, etc.)
- Lets chefs count stock by tapping +/− buttons — no spreadsheets, no typing
- Shows at a glance what's low, what's fine, and what needs ordering
- Auto-generates order lists from below-par items with one tap
- Feeds directly into the existing SupplierHub ordering workflow
- Tracks stock movements over time (counts, deliveries received, waste)

**The key insight**: SupplierHub already knows what products the restaurant buys (from order lists and supplier order guides). The inventory module reuses this product data so chefs don't have to set up a product catalog from scratch.

---

## 4. Target Users

| User | Role in Inventory | Key Needs |
|------|-------------------|-----------|
| **Chef** | Primary user — takes daily counts, receives deliveries, records waste | Speed, simplicity, works on a phone one-handed in a walk-in |
| **Sous Chef / Line Cook** | May take counts for their station or area | Same as chef — needs to be dead simple |
| **Owner / Manager** | Reviews stock levels, waste reports, ordering trends across locations | Dashboard visibility without having to be in the kitchen |

### Design Principles for Non-Technical Chefs

1. **Tap, don't type** — increment/decrement buttons, not text fields
2. **Visual, not numerical** — green/yellow/red status, not raw numbers to interpret
3. **Mirrors the physical space** — organized by storage area, not alphabetically
4. **Auto-saves everything** — no "submit" buttons, no lost work
5. **Builds on existing data** — seeds from order lists and supplier guides they already use
6. **Leads to action** — every screen answers "what do I do next?"
7. **Works offline-ish** — must handle spotty kitchen Wi-Fi gracefully (optimistic saves, retry queue)

---

## 5. Business Objectives

| Objective | Metric | Target |
|-----------|--------|--------|
| Increase platform stickiness | Daily active users (inventory creates a daily habit) | 3x daily opens per chef vs. current |
| Drive order volume through SupplierHub | Orders originating from "Build Order" in inventory | 40% of orders within 6 months |
| Reduce food waste | Self-reported waste value tracked in the module | Visible trend data within 3 months |
| Differentiate from competitors | No competitor connects inventory counting to live supplier ordering at our price point | Unique feature at launch |
| Expand to owner persona | Owner dashboard engagement with inventory data | Owners check inventory stats 2x/week |

---

## 6. Feature Requirements

### Phase 1: Core Inventory (MVP)

> **Goal**: A chef can count stock, see what's low, and build an order from it.

#### 6.1 Storage Areas

Inventory is organized by physical storage zones within each restaurant location.

| Requirement | Details |
|-------------|---------|
| Default areas | Walk-in Cooler, Dry Storage, Freezer, Prep Station / Line |
| Custom areas | Users can add, rename, reorder, or remove areas |
| Per-location | Each Location has its own set of areas |
| Visual identity | Each area has an icon/emoji for quick recognition |
| Sortable | Drag-to-reorder so the list matches the chef's physical walk path |

#### 6.2 Inventory Items

Each item represents a product the kitchen tracks, placed in a storage area.

| Field | Type | Notes |
|-------|------|-------|
| Product link | FK → Product | Links to canonical product for supplier/pricing data |
| Display name | String | Chef-friendly override (e.g., "Tomatoes" instead of "ROMA TOMATOES 25LB CASE") |
| Storage area | FK → InventoryArea | Where this item lives physically |
| Current quantity | Decimal | On-hand count |
| Par level | Decimal | Target minimum stock level |
| Unit label | String | Freeform — "cases", "bags", "each", "lbs", "#10 cans" |
| Position | Integer | Sort order within the area |
| Last counted at | Timestamp | When this item was last touched during a count |

#### 6.3 Quick Count (Daily Workflow)

The primary interaction — a chef walks through a storage area counting items.

| Requirement | Details |
|-------------|---------|
| Area selection | Chef picks which area to count (or "Full Count" for all) |
| Card-based UI | One item per row — large, touch-friendly |
| +/− buttons | Tap to increment or decrement by 1 (long-press for fast repeat) |
| Direct entry | Tap the number to type a value (for big changes like "received 12 cases") |
| Auto-save | Every change saves immediately — no submit button |
| Visual status | Each item shows green (at/above par), yellow (below par), red (zero/critical) |
| "Checked" indicator | Items change appearance after being counted in this session so the chef can see what's left |
| Progress | "8 of 24 items counted" indicator |
| Completion | "Done" screen with summary: items counted, items below par, suggested action |

#### 6.4 Par Levels & Status

| Status | Condition | Visual | Action |
|--------|-----------|--------|--------|
| **Stocked** | quantity >= par_level | Green badge | None |
| **Low** | 0 < quantity < par_level | Yellow badge | Consider ordering |
| **Out** | quantity = 0 | Red badge | Order immediately |
| **No par set** | par_level is null | Gray badge | Suggest setting a par |

#### 6.5 Build Order from Inventory

The feature that connects inventory to SupplierHub's existing ordering.

| Requirement | Details |
|-------------|---------|
| "Low Stock" view | Filtered list of all items below par level |
| "Build Order" button | Creates a new OrderList with quantity = (par_level − current_quantity) for each low item |
| Product matching | Uses the Product → SupplierProduct link to find orderable items |
| Review step | Chef sees the generated list, can adjust quantities or remove items before proceeding |
| Handoff | After review, routes to the existing Order Builder with the new list pre-loaded |
| Unmatched items | Items without a linked Product are flagged: "We can't find this from your suppliers — add it manually?" |

#### 6.6 Setup / Onboarding

First-time setup should take under 5 minutes.

| Requirement | Details |
|-------------|---------|
| Import from Order Lists | Pull products from the chef's existing OrderLists into inventory |
| Import from Supplier Guides | Pull products from synced SupplierLists (order guides) |
| Start from scratch | Blank slate with product search to add items one by one |
| Bulk area assignment | After import, let chef drag or assign items to storage areas in bulk |
| Skip par levels | Par levels can be set later — don't force them during setup |
| Tutorial cards | 3-4 contextual tips that show once and dismiss (not a video, not a manual) |

---

### Phase 2: Stock Movement Tracking

> **Goal**: Inventory quantities update automatically from deliveries and track waste.

#### 6.7 Receive Delivery

| Requirement | Details |
|-------------|---------|
| Trigger | From a completed Order — "Mark Received" button |
| Pre-filled quantities | Shows ordered quantities; chef confirms or adjusts what actually arrived |
| Partial receiving | Chef can mark some items received now, others later (e.g., backordered) |
| Inventory update | Confirmed quantities automatically add to current_quantity |
| Discrepancy notes | Chef can note "ordered 5 cases, received 4" — logged for owner visibility |
| Standalone receiving | Also allow receiving without a linked order (for walk-in purchases, farmer's market, etc.) |

#### 6.8 Waste / Spoilage Tracking

| Requirement | Details |
|-------------|---------|
| Quick log | From any inventory item: "Record Waste" → enter quantity + reason (expired, spoiled, damaged, overproduction, other) |
| Quantity decrease | Waste reduces current_quantity |
| History | All waste entries logged with user, timestamp, reason, quantity |
| Owner reports | Waste summary by period, area, category — visible on owner dashboard |

#### 6.9 Count History & Audit Trail

| Requirement | Details |
|-------------|---------|
| Every change logged | All quantity changes recorded: who, when, previous value, new value, type (count/received/waste/adjustment) |
| Counting sessions | Optionally group counts into a "session" (started at / completed at) so owners can see when counts happened |
| Item history | Per-item timeline view: "Mar 3 — counted 4 cases (was 6) by Chef Mike" |

---

### Phase 3: Intelligence & Automation

> **Goal**: The system starts suggesting actions and surfacing insights.

#### 6.10 Usage Trends & Forecasting

| Requirement | Details |
|-------------|---------|
| Usage calculation | Infer daily usage from count deltas: (previous count + received − waste − current count) / days between counts |
| Trend display | Per-item sparkline or simple "you use ~3 cases/week" label |
| Days remaining | "At current usage, you have ~2 days of stock left" |
| Smart par suggestions | "Based on your usage and delivery schedule, we suggest a par of 5 cases" |

#### 6.11 Automated Low-Stock Alerts

| Requirement | Details |
|-------------|---------|
| Push notification | When an item drops below par (from a count or waste entry), notify the chef |
| Daily summary | Morning digest: "5 items are below par at [Location Name]" |
| Owner rollup | Weekly summary across all locations for owners |
| Configurable | Alerts can be turned on/off per user, per location |

#### 6.12 Auto-Order Suggestions

| Requirement | Details |
|-------------|---------|
| Delivery-aware timing | "You have 2 days of tomatoes left. US Foods delivers on Tuesday. Order by Monday 6 PM." |
| Pre-built order | System drafts an OrderList based on par shortfalls + delivery schedule |
| One-tap approval | Chef reviews and taps "Place Order" — routes to existing checkout flow |
| Learns over time | Adjusts suggestions based on actual ordering patterns vs. pars |

---

## 7. Data Model

```
┌─────────────────────┐       ┌─────────────────────┐
│     Location         │       │     Product          │
│  (existing model)    │       │  (existing model)    │
└──────────┬──────────┘       └──────────┬──────────┘
           │ has_many                     │
           │                              │
    ┌──────▼──────────┐                   │
    │  InventoryArea   │                   │
    │                  │                   │
    │  - location_id   │                   │
    │  - name          │                   │
    │  - icon          │                   │
    │  - position      │                   │
    └──────┬──────────┘                   │
           │ has_many                     │
           │                              │
    ┌──────▼──────────────────────────────▼──┐
    │         InventoryItem                   │
    │                                         │
    │  - location_id (indexed)                │
    │  - inventory_area_id                    │
    │  - product_id (FK → Product)            │
    │  - display_name                         │
    │  - current_quantity (decimal)            │
    │  - par_level (decimal, nullable)        │
    │  - unit_label (string)                  │
    │  - position (integer)                   │
    │  - last_counted_at (timestamp)          │
    └──────────────┬──────────────────────────┘
                   │ has_many
                   │
    ┌──────────────▼──────────────────────────┐
    │         InventoryCount                   │
    │  (immutable audit log)                   │
    │                                          │
    │  - inventory_item_id                     │
    │  - user_id (who made this change)        │
    │  - quantity (new value recorded)          │
    │  - previous_quantity                      │
    │  - change_type:                           │
    │      count | received | waste |           │
    │      adjustment | initial                 │
    │  - reason (nullable — for waste)          │
    │  - notes (nullable — freeform)            │
    │  - session_id (FK, nullable)              │
    │  - counted_at (timestamp)                 │
    └─────────────────────────────────────────┘

    ┌─────────────────────────────────────────┐
    │       InventorySession (optional)        │
    │                                          │
    │  - location_id                           │
    │  - inventory_area_id (null = full count) │
    │  - user_id                               │
    │  - started_at                            │
    │  - completed_at (nullable)               │
    │  - items_counted (integer)               │
    └─────────────────────────────────────────┘
```

### Multi-Tenant Scoping

| Model | Scoped To | Access Rules |
|-------|-----------|-------------|
| InventoryArea | Location | All users at that location can see; owners see all locations |
| InventoryItem | Location | Same as above |
| InventoryCount | Location (via item) | Same; immutable after creation |
| InventorySession | Location | User who created it; owners can view all |

### Integration with Existing Models

| Existing Model | Integration |
|----------------|-------------|
| **Product** | InventoryItem links to canonical Product, which links to SupplierProducts for pricing and ordering |
| **OrderList** | "Build Order" creates a new OrderList populated from below-par InventoryItems |
| **OrderListItem** | Each below-par item becomes an OrderListItem with quantity = (par − current) |
| **Order** | Completed orders can trigger "Mark Received" flow to update inventory |
| **SupplierList** | Supplier order guides can seed InventoryItems during setup |
| **SupplierDeliverySchedule** | Phase 3 uses delivery days to time reorder suggestions |
| **Location** | All inventory data is per-location |

---

## 8. User Flows

### 8.1 First-Time Setup (< 5 minutes)

```
Inventory nav item → "Set Up Inventory" landing page
  │
  ├─ "Import from My Order Lists" (recommended if they have lists)
  │    → Select which lists to import
  │    → Products added as InventoryItems
  │
  ├─ "Import from Supplier Guides" (recommended if lists are empty)
  │    → Select supplier order guides to pull from
  │    → Products added as InventoryItems
  │
  └─ "Start from Scratch"
       → Empty inventory, search to add items
  │
  ▼
  Assign items to storage areas
  (drag & drop, or "Move to…" dropdown)
  │
  ▼
  Optional: Set par levels now or skip for later
  │
  ▼
  "Start Counting" → first Quick Count session
```

### 8.2 Daily Morning Count

```
Dashboard → "Take Inventory" (or Inventory nav item)
  │
  ▼
  Select area: [Walk-in] [Dry Storage] [Freezer] [All]
  │
  ▼
  Card list of items in selected area
  ┌─────────────────────────────────────────┐
  │  🍅 Tomatoes, Roma          [−] 3 [+]  │
  │     Par: 5 cases          ● Below par   │
  │                                         │
  │  🧀 Mozzarella, Fresh      [−] 8 [+]  │
  │     Par: 6 bags           ● Stocked     │
  │                                         │
  │  🫒 Olive Oil, EVOO        [−] 0 [+]  │
  │     Par: 2 jugs           ● Out         │
  └─────────────────────────────────────────┘
  │
  │ Each tap auto-saves. Colors update live.
  │
  ▼
  "Done" → Summary: 18 items counted, 4 below par
  │
  └─ [Build Order for Low Items]
       → Creates OrderList → routes to Order Builder
```

### 8.3 Receive a Delivery (Phase 2)

```
Orders → Completed order → "Mark Received"
  │
  ▼
  List of ordered items, pre-filled with ordered quantities
  ┌───────────────────────────────────────────────┐
  │  Roma Tomatoes 25lb     Ordered: 5   Got: [5] │
  │  Olive Oil 1gal         Ordered: 2   Got: [2] │
  │  Mozzarella 5lb         Ordered: 3   Got: [2] │  ← short
  └───────────────────────────────────────────────┘
  │
  ▼
  "Confirm Received" → inventory quantities updated
  Short items flagged with optional note
```

### 8.4 Record Waste (Phase 2)

```
Inventory item → "Adjust" → "Record Waste"
  │
  ▼
  Quantity: [___]
  Reason:  [Expired ▾]  (expired, spoiled, damaged, overproduction, other)
  Notes:   [optional___________]
  │
  ▼
  "Save" → quantity decreases, logged in history
```

---

## 9. Dashboard Integration

### Chef Dashboard Widget

```
┌──────────────────────────────────┐
│  📦 Inventory Snapshot           │
│                                  │
│  4 items below par               │
│  0 items out of stock            │
│  Last count: Today 6:15 AM      │
│                                  │
│  [Take Inventory]  [View All]   │
└──────────────────────────────────┘
```

### Owner Dashboard Widget

```
┌──────────────────────────────────────────┐
│  📦 Inventory Across Locations            │
│                                          │
│  Main St:   2 low · 0 out · Counted today│
│  Downtown:  5 low · 1 out · Counted yesterday│
│  Catering:  — not set up —               │
│                                          │
│  Waste this week: $342                   │
│  [View Details]                          │
└──────────────────────────────────────────┘
```

---

## 10. Competitive Landscape

| Platform | Inventory | Connected Ordering | Price |
|----------|-----------|-------------------|-------|
| **BlueCart** | Yes | Own marketplace only | $300-500/mo |
| **MarketMan** | Yes | Integrations (limited) | $250-800/mo |
| **Craftable (formerly Bevager)** | Yes | Manual | $300-500/mo |
| **xtraCHEF (Toast)** | Invoice-based | Toast POS only | Bundled w/ Toast |
| **Simple Order** | Basic | Own marketplace | $200/mo |
| **SupplierHub** | **Planned** | **Direct to supplier portals** | **Current pricing** |

**Our advantage**: We're the only platform where inventory counting directly triggers orders through the restaurant's own supplier accounts at their negotiated prices. Every competitor either has their own marketplace (different prices), requires manual order entry after counting, or locks you into a single POS ecosystem.

---

## 11. Non-Functional Requirements

| Requirement | Specification |
|-------------|---------------|
| **Mobile performance** | Quick Count screen must load in < 2 seconds on 4G |
| **Auto-save latency** | Quantity changes saved within 500ms (optimistic UI) |
| **Offline tolerance** | Changes queued locally if connection drops, synced when restored |
| **Data retention** | InventoryCount history retained for 12 months minimum |
| **Multi-user safety** | If two chefs count the same item simultaneously, last-write-wins with conflict indicator |

---

## 12. Phasing & Milestones

| Phase | Scope | Goal |
|-------|-------|------|
| **Phase 1 — Core** | Storage areas, inventory items, Quick Count, par levels, "Build Order" button, setup import | Chef can count stock and generate orders from it |
| **Phase 2 — Tracking** | Receive deliveries, waste logging, count history, audit trail | Full stock movement tracking |
| **Phase 3 — Intelligence** | Usage trends, low-stock alerts, delivery-aware suggestions, auto-order drafts | System proactively helps the chef stay stocked |

### Suggested Timeline

| Phase | Duration | Dependencies |
|-------|----------|-------------|
| Phase 1 | 3-4 weeks | None — builds on existing Product/OrderList models |
| Phase 2 | 2-3 weeks | Phase 1 complete; hooks into existing Order model |
| Phase 3 | 3-4 weeks | Phase 2 complete; uses SupplierDeliverySchedule data |

---

## 13. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Chefs won't adopt — too many steps | Medium | High | Design for < 5 minutes daily. If it's slower than a clipboard, we've failed |
| Product matching gaps — inventory item can't find a supplier product | Medium | Medium | Allow unmatched items (chef can still count them); surface "match this product" prompts |
| Stale counts — chefs forget to count | Medium | Medium | Morning reminder notifications (Phase 3); dashboard badges showing "last counted 3 days ago" |
| Multi-location complexity for owners | Low | Medium | Keep each location independent. Owner views are read-only aggregation |
| Scope creep into recipe costing / POS integration | High | Medium | Explicitly out of scope for all 3 phases. Evaluate after Phase 3 |

---

## 14. Out of Scope (for now)

These are valuable features but intentionally deferred:

- **Recipe costing** — calculating dish costs from inventory prices
- **POS integration** — auto-decrementing stock when dishes are sold
- **Barcode/QR scanning** — scanning items to find them in inventory
- **FIFO/lot tracking** — tracking which batch of an item to use first
- **Multi-unit conversion** — auto-converting "cases" to "each" (unit_label stays freeform)
- **Vendor invoice scanning** — OCR invoices to update received quantities
- **API for third-party integrations** — opening inventory data to other systems

---

## 15. Success Criteria

| Metric | Phase 1 Target | Phase 3 Target |
|--------|---------------|----------------|
| Setup completion rate | 70% of chefs who start setup finish it | — |
| Daily count adoption | 30% of active chefs count at least 3x/week | 60% |
| Orders from inventory | 15% of orders originate from "Build Order" | 40% |
| Time to complete a count | Under 10 minutes for a full count | Under 5 minutes |
| Waste tracking adoption | — | 40% of locations log waste weekly |
| Net Promoter Score (inventory feature) | — | 50+ |

---

## 16. Open Questions

1. **Unit standardization** — Should we eventually normalize units (e.g., know that 1 case = 6 #10 cans) or keep it freeform? Freeform is simpler but limits intelligence in Phase 3.

2. **Shared vs. personal inventory** — Is inventory per-location (shared by all staff) or can individual chefs have their own station-level counts? Recommendation: per-location for Phase 1.

3. **Pricing in inventory view** — Should the inventory screen show current supplier prices for each item? Useful for owners tracking food cost, but adds visual noise for chefs just counting.

4. **Integration with Event Menu Planner** — When a chef plans an event menu, should it check current inventory and only order the delta? Natural fit but adds cross-feature complexity.

5. **Free tier vs. paid** — Is inventory included in the current subscription or a premium add-on?
