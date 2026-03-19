# Product Requirements Document: Owner Onboarding Wizard Refresh

**Feature Name**: Owner Post-Setup Getting Started Flow
**Status**: Draft
**Date**: 2026-03-18

---

## 1. Executive Summary

The current owner onboarding wizard covers account scaffolding well: create an organization, add a restaurant, invite a team member, and optionally connect a supplier. But it stops there. Owners are the users who set organizational standards — they create the master lists, promote them to the whole team, and manage the supplier relationships. None of that is introduced by the current wizard.

This PRD proposes extending the owner onboarding with post-setup Getting Started steps that guide owners through the operational workflow they need to establish before their team can be effective: **review matches → create order lists → promote lists org-wide → place a first order**.

---

## 2. Problem Statement

After completing the setup wizard, owners land on a dashboard full of KPI cards that all show $0.00. They've done the admin work (org, restaurants, team) but haven't touched the product that generates those numbers.

1. **No bridge from setup to operations** — The wizard ends at "connect a supplier" (optional). The next thing an owner needs to do — review matched products and create standardized order lists — is never introduced.
2. **List promotion is invisible** — The promote/demote feature is how owners enforce consistency across locations and chefs. An owner who doesn't know about promotion will end up with every chef building their own ad-hoc lists, defeating the purpose of centralized purchasing.
3. **Owner does chef work first** — Before an owner can promote anything, they need to go through the same review-matches → create-order-lists flow a chef does. But the owner wizard doesn't share any steps with the chef workflow.
4. **Empty dashboard problem** — An owner who completes the setup wizard but doesn't place orders sees a dashboard with all zeros, which feels broken. The Getting Started flow should get them to their first order quickly so the dashboard has data.

| Gap | Impact |
|-----|--------|
| No matched-list introduction | Owner doesn't know the core product exists |
| Order lists not introduced | No standardized templates get created |
| Promotion not surfaced | Chefs build inconsistent lists; owner loses control |
| Empty KPI dashboard | App feels incomplete after setup |

---

## 3. Proposed Solution

Keep the existing hard-gate wizard (create org → add restaurant → invite team) and the optional "connect supplier" step exactly as they are. After those complete, replace the current inline "Finish Setting Up" card on the owner dashboard with an expanded Getting Started checklist.

### Post-Setup Getting Started Checklist (Owner)

| Step | Title | Description | Done When |
|------|-------|-------------|-----------|
| 1 | Connect a supplier | Link your supplier account to pull in pricing and order guides | `supplier_credentials.where(status: 'active').any?` (already exists as optional step 4) |
| 2 | Review your product matches | Your supplier catalogs have been matched across vendors — confirm the matches are correct | Owner has visited the aggregated list, or has confirmed at least one match |
| 3 | Create an order list | Build a reusable order template for your team — like "Weekly Produce" or "Protein Order" | `order_lists.any?` for this org |
| 4 | Promote a list for your team | Share a list org-wide so all locations and chefs order from the same standard template | Any aggregated list or order list has been promoted |
| 5 | Place your first order | Use the order builder to compare prices across suppliers and submit an order | `orders.any?` for this org |

### Sync Status (Same as Chef)

Between step 1 and step 2, the background sync needs to complete. Same messaging as the chef wizard:
- "Your supplier data is syncing — products will be matched and ready in a few minutes."
- Step 2 becomes actionable once an aggregated list with matches exists.

### Promotion Step Detail

Step 4 is unique to owners. The description should explain *why* promotion matters:
- "When you promote a list, it becomes available to every chef and location in your organization. This ensures your team orders from a consistent, approved set of products and suppliers."
- Link goes to the aggregated list page with a visual indicator on the promote action.

### Behavior

- Replaces the current inline `@onboarding_steps` card on `_owner_dashboard.html.erb` (lines 67-124)
- Uses the same dismissable pattern (`onboarding_dismissed_at`)
- Steps are checked dynamically, not stored
- Not hard-gated — owner can navigate freely, checklist is guidance only
- The existing full-page wizard (hard-gate for org/restaurant/team) is completely unchanged

---

## 4. What's NOT Changing

- Hard-gate wizard steps 1-3 (create org, add restaurant, invite team) — untouched
- The `onboarding_incomplete?` logic in ApplicationController — untouched
- The `owner_setup_in_progress?` logic that keeps the full-page wizard visible for optional steps — this may need to be revisited to hand off to the new inline checklist, but the hard-gate behavior stays
- No new database tables or columns needed

---

## 5. Transition: Full-Page Wizard → Inline Checklist

Currently, after the required steps complete, the owner stays on the full-page wizard if optional steps remain (controlled by `owner_setup_in_progress?`). With the new checklist:

- **Option A**: Drop the full-page wizard as soon as required steps are done, show the dashboard with the inline checklist immediately. The "connect supplier" step moves into the checklist.
- **Option B**: Keep the full-page wizard for "connect supplier" only, then transition to the inline checklist for steps 2-5.

Recommendation: **Option A** — it's simpler. The owner sees their (empty) dashboard immediately with the Getting Started card guiding them through the remaining steps. This also eliminates the "Exit Wizard" button complexity.

---

## 6. Completion Criteria

- [ ] Owner dashboard shows revised Getting Started checklist with 5 steps after hard-gate wizard completes
- [ ] Checklist includes promotion step with explanation of org-wide impact
- [ ] Sync status messaging between credential connection and matches being ready
- [ ] Each step links to the correct page
- [ ] Checklist is dismissable and stays dismissed
- [ ] Steps reflect actual completion state dynamically
- [ ] Full-page wizard only appears for the 3 hard-gated steps (org, restaurant, team)

---

## 7. Open Questions

1. Should "connect supplier" remain an optional step in the full-page wizard AND appear as step 1 in the inline checklist, or should it move entirely to the inline checklist?
2. Should the promote step link to a specific aggregated list, or to the aggregated lists index? If the owner only has one list, linking directly makes sense.
3. Should the checklist track per-location completion? An owner with 3 restaurants might need to promote lists to all 3.
4. Should the "Place your first order" step count any org member's order, or specifically the owner's? Owners may delegate ordering to chefs and never place one themselves.
