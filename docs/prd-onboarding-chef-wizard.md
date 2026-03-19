# Product Requirements Document: Chef Onboarding Wizard Refresh

**Feature Name**: Chef Post-Setup Getting Started Flow
**Status**: Draft
**Date**: 2026-03-18

---

## 1. Executive Summary

The current chef onboarding wizard has a single hard-gate step: connect a supplier credential. Once that's done, the chef lands on their dashboard with no guidance on what to do next. The supplier sync runs in the background, and within minutes the chef has aggregated lists with AI-matched products sitting in the system — but nothing tells them that, or walks them through the core workflow of reviewing matches, creating order lists, and placing orders.

This PRD proposes extending the chef onboarding with a post-setup Getting Started checklist that guides chefs through the actual value loop of the product: **review matches → create order lists → build an order → place it**.

---

## 2. Problem Statement

After connecting a supplier, chefs face a dead end:

1. **No awareness of background sync** — Credentials are connected, the scraper runs, order guides are imported, an aggregated list is created, and product matching runs — all silently. The chef has no idea this is happening or when it's done.
2. **No path to the core product** — The aggregated list (matched products across suppliers) is the heart of the app. Nothing points the chef there after setup.
3. **Order lists aren't introduced** — Order lists (reusable templates like "Weekly Produce" or "Friday Fish") are what make the ordering workflow practical for daily use. Chefs won't discover these on their own.
4. **The order builder isn't surfaced** — The flagship ordering UX where you compare prices and set quantities is buried behind navigation the chef has never seen.

| Gap | Impact |
|-----|--------|
| No sync status visibility | Chef doesn't know when their data is ready |
| No introduction to matched lists | Core feature goes undiscovered |
| No order list creation guidance | Chef orders from the full catalog every time, which is overwhelming |
| No order builder walkthrough | Chef may not understand the price comparison workflow |

---

## 3. Proposed Solution

Extend the existing Getting Started cards on the chef dashboard (currently: "Connect a supplier" and "Import your order lists") with a revised checklist that reflects the actual user workflow. Remove "Import your order lists" since imports happen automatically.

### Post-Setup Getting Started Checklist (Chef)

| Step | Title | Description | Done When |
|------|-------|-------------|-----------|
| 1 | Connect a supplier | Link your supplier account to pull in pricing and order guides | `supplier_credentials.any?` (already exists) |
| 2 | Review your product matches | Your supplier catalogs have been matched — confirm the AI got the right products paired up | Chef has visited the aggregated list page, or has confirmed at least one match |
| 3 | Create an order list | Build a reusable list for your regular orders — like "Weekly Produce" or "Dry Goods" | `order_lists.any?` for this user |
| 4 | Place your first order | Use the order builder to compare prices, set quantities, and submit an order | `orders.any?` for this user |

### Sync Status Awareness

Between step 1 completing and step 2 becoming actionable, there's a gap while the background sync runs. The checklist should handle this:

- If credentials are connected but no aggregated list exists yet, step 2 should show: "Your supplier data is syncing — this usually takes a few minutes. We'll have your products matched and ready shortly."
- Once the aggregated list exists and has matches, step 2 becomes actionable with a link to the list.

### Behavior

- The checklist replaces the current `@getting_started` cards on `_chef_dashboard.html.erb`
- Dismissable via the existing `onboarding_dismissed_at` mechanism
- Steps are checked dynamically (not stored as state) — same pattern as the current wizard
- Steps are sequential but not hard-gated — a chef can navigate anywhere, the checklist just tracks progress

---

## 4. What's NOT Changing

- The hard-gate wizard (must connect a supplier before accessing the app) stays as-is
- The `ensure_onboarding_complete` before_action in ApplicationController is unchanged
- No new database columns needed beyond what exists
- The checklist is guidance, not enforcement — chefs are never blocked from using the app after the initial credential gate

---

## 5. Completion Criteria

- [ ] Chef dashboard shows revised Getting Started checklist with 4 steps
- [ ] "Import your order lists" step is removed (it's not a user action)
- [ ] Sync status is communicated between credential connection and matches being ready
- [ ] Each step links to the correct page (aggregated list, new order list, order builder)
- [ ] Checklist is dismissable and stays dismissed across sessions
- [ ] Steps reflect actual completion state on each page load

---

## 6. Open Questions

1. Should step 2 ("Review your product matches") auto-complete when the chef visits the aggregated list, or only when they explicitly confirm at least one match?
2. Do we want a Turbo Stream or polling mechanism to update the sync status in real-time, or is a page refresh sufficient?
3. Should the checklist reappear if a chef connects a second supplier (new matches to review)?
