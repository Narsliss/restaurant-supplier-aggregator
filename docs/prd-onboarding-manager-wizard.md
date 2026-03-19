# Product Requirements Document: Manager Onboarding

**Feature Name**: Manager Getting Started Flow
**Status**: Draft
**Date**: 2026-03-18

---

## 1. Executive Summary

Managers currently have zero onboarding. They accept an invitation, log in, and land on a read-only dashboard showing spending stats, order history, and restaurant performance — with no context about what they're looking at, what their role allows them to do, or what actions they should take.

This is the only role with no setup wizard and no Getting Started guidance. This PRD proposes adding a lightweight onboarding experience that orients managers to their oversight capabilities and helps them understand the data they're seeing.

---

## 2. Problem Statement

Managers are an oversight role — they don't place orders or manage suppliers, but they monitor spending, review orders across locations, and track team activity. The problem is nobody tells them that.

1. **Cold landing** — A manager accepts an invite and immediately sees a dashboard with KPI cards, spending charts, and order tables. If the org is new, everything shows $0.00 with no explanation. If the org is active, the manager sees data with no context about what it means or what they should do with it.
2. **Role confusion** — Without any onboarding, a manager doesn't know the boundaries of their role. Can they place orders? (No.) Can they manage suppliers? (No.) Can they invite people? (No.) They have to discover these limits by clicking around and finding things disabled or missing.
3. **No guided exploration** — The manager dashboard has real value: spending by restaurant, spending by supplier, weekly trends, order history. But a first-time manager doesn't know which metrics to focus on or what actions to take when they spot something (e.g., one restaurant spending 3x more than another).

| Gap | Impact |
|-----|--------|
| No welcome or orientation | Manager feels dropped into someone else's dashboard |
| No role explanation | Manager wastes time looking for features they can't access |
| No guidance on available views | Valuable reports and breakdowns go undiscovered |
| Empty state not handled | New org manager sees all zeros with no explanation |

---

## 3. Proposed Solution

Add a Getting Started experience for managers. Since managers don't have setup tasks (no credentials to connect, no lists to create), this is less of a step-by-step checklist and more of an **orientation card** that explains what they can see and do.

### Option A: Orientation Card (Recommended)

A single dismissable card on the manager dashboard that welcomes them and explains their role. Not a multi-step checklist — managers don't have sequential tasks to complete.

**Card content:**

> **Welcome to SupplierHub, [Name]!**
>
> As a manager, you have a bird's-eye view of your organization's ordering activity. Here's what you can do:
>
> - **Track spending** — See total spend, savings, and trends across all restaurants and suppliers
> - **Review orders** — View order history from all team members and locations
> - **Monitor restaurants** — Compare spending and order volume across your locations
> - **Analyze suppliers** — See which suppliers your team orders from most and where savings opportunities exist
>
> Your team's chefs handle day-to-day ordering. You'll see their activity reflected here automatically.

**Behavior:**
- Shown on first login (when `onboarding_dismissed_at` is nil)
- Dismissable — once dismissed, never shown again
- Uses the same `onboarding_dismissed_at` column as other roles
- Positioned at the top of the manager dashboard, above the KPI cards

### Option B: Exploration Checklist (Alternative)

If we want the manager onboarding to feel consistent with the chef and owner checklists, use a lightweight checklist of "have you seen this?" steps:

| Step | Title | Description | Done When |
|------|-------|-------------|-----------|
| 1 | Review your dashboard | See spending, savings, and order trends at a glance | Auto-complete on first dashboard visit (or just always checked) |
| 2 | Check spending by restaurant | See which locations are spending the most | Manager has visited the reports page, or clicked into a location breakdown |
| 3 | View recent orders | Review orders placed by your team across all locations | Manager has viewed at least one order detail page |

**Concern with Option B:** These aren't real tasks — they're just "click here to see this page." A checklist implies work to be done, and managers don't have work to do in the setup sense. Option A is more honest about what the role is.

---

## 4. Empty State Handling

For new organizations where the manager logs in before any orders have been placed:

- KPI cards should show "$0.00" with a note: "Orders placed by your team will appear here"
- The weekly trend chart should show empty bars with a label: "Spending data will populate as your team places orders"
- The order history table should show an empty state: "No orders yet — your chefs will start placing orders through SupplierHub soon"

This is separate from the Getting Started card but equally important. A manager seeing all zeros with no explanation will think the app is broken.

---

## 5. What About the Hard Gate?

Managers currently bypass `onboarding_incomplete?` entirely — they have no required setup steps. This should stay the same. Managers don't need to do anything before accessing the app. The orientation card is purely informational.

The `skip_onboarding_check?` logic in ApplicationController doesn't need to change. Managers already pass through `onboarding_incomplete?` because the method returns `false` for non-owner, non-chef roles.

---

## 6. What's NOT Changing

- Manager dashboard layout and data — untouched
- The `@read_only = true` flag on the manager dashboard — untouched
- No new permissions or capabilities for managers
- No new database columns (reuses `onboarding_dismissed_at`)
- No hard-gate or blocked access — managers can always use the full app

---

## 7. Completion Criteria

- [ ] Manager sees a welcome/orientation card on first login
- [ ] Card explains the manager role and available capabilities
- [ ] Card is dismissable and stays dismissed across sessions
- [ ] Empty states on KPI cards, charts, and order tables explain that data will appear when the team starts ordering
- [ ] No hard-gate — managers are never blocked from navigating

---

## 8. Open Questions

1. Should the orientation card include direct links to specific dashboard sections (e.g., "Jump to spending by restaurant"), or is the text description sufficient since everything is on the same page?
2. Should managers see a notification or badge when notable activity happens (e.g., a large order is placed, spending spikes at a location)? This is out of scope for onboarding but would make the manager role more active and engaged.
3. If a manager is later promoted to owner, should they see the owner Getting Started checklist? The `onboarding_dismissed_at` would already be set from the manager orientation — we may need to reset it or track dismissal per-role.
4. Should the manager dashboard show a "tip of the day" or contextual hints on specific metrics (e.g., "This restaurant's spending is 40% above average — tap to see their recent orders")? Out of scope but worth considering for v2.
