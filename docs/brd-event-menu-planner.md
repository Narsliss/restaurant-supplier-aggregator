# Business Requirements Document: AI Event Menu Planner

**Feature Name**: AI Event Menu Planner
**Status**: Draft
**Branch**: `prototype` (experimental)
**Date**: 2026-03-01

---

## 1. Executive Summary

SupplierHub currently helps restaurants compare prices and order from multiple food suppliers. The AI Event Menu Planner extends this by allowing chefs to plan event menus through a conversational AI interface that generates wine-paired menus, sources ingredients from their connected suppliers at real prices, and builds purchase orders — all from a single natural-language prompt.

---

## 2. Problem Statement

When planning a special event (wine dinner, tasting menu, holiday banquet), chefs currently:

1. **Research wine pairings manually** — reading tasting notes, consulting sommeliers, or relying on experience
2. **Draft a menu on paper or in a spreadsheet** — iterating course by course, considering flavor profiles and dietary variety
3. **Estimate ingredient quantities by hand** — scaling recipes to the expected cover count
4. **Search supplier catalogs individually** — checking US Foods, Chef's Warehouse, etc. one by one for each ingredient
5. **Calculate food costs manually** — tallying ingredient costs, dividing by covers, adjusting dishes to hit a target cost
6. **Place separate orders** — entering items into each supplier's ordering system

This process takes hours and involves multiple tools, websites, and spreadsheets. There is no single tool that connects menu ideation to real supplier pricing and ordering.

---

## 3. Proposed Solution

A conversational AI interface within SupplierHub where a chef can describe an event and receive a complete, costed menu plan tied to their real supplier catalog.

**Example interaction:**

> **Chef**: "I have a wine dinner coming up next Saturday. We're pouring 5 wines: a 2020 Chablis Premier Cru, a Sancerre Rosé, a Barolo, a Châteauneuf-du-Pape, and a Sauternes for dessert. Expecting 50 covers, and I'd like to keep food cost around $100 per cover."
>
> **System**: Generates a 5-course menu with tasting notes for each wine, pairing rationale, dish descriptions, a full ingredient list with quantities for 50 covers, matched ingredients from the chef's connected suppliers with real prices, and a cost breakdown showing $94.50/cover.
>
> **Chef**: "The lamb rack is too expensive. Can you suggest a cheaper protein for the Barolo course?"
>
> **System**: Suggests braised short ribs instead, updates the menu and recalculates costs to $87.20/cover.
>
> **Chef**: "Perfect. Build the order."
>
> **System**: Creates purchase orders grouped by supplier and takes the chef to the order review page.

---

## 4. Business Objectives

| Objective | Metric |
|-----------|--------|
| Increase platform stickiness | Event plans created per active org per month |
| Drive order volume | Orders originating from menu planner |
| Reduce event planning time | Time from concept to placed order (target: under 15 minutes) |
| Differentiate from competitors | Feature uniqueness — no competitor ties AI menu generation to real supplier ordering |

---

## 5. Users & Personas

### Primary: Executive Chef / Chef de Cuisine
- Plans special events (wine dinners, holiday menus, private parties)
- Deep food knowledge but limited time for sourcing and cost calculations
- Wants creative menu suggestions that respect budget constraints
- Already has supplier credentials connected in SupplierHub

### Secondary: Sous Chef / Kitchen Manager
- Responsible for ordering based on a menu the head chef designed
- Uses the platform to convert a finalized menu into actual orders
- Cares most about accurate quantities and cost tracking

### Tertiary: Restaurant Owner / GM
- Reviews event food costs
- Wants visibility into planned vs actual spend

---

## 6. User Stories

### Epic: Event Plan Creation

**US-1: Start a new event plan**
As a chef, I want to start a new event plan so I can describe my upcoming event.
- Acceptance Criteria:
  - "Menu Planner" link visible in main navigation
  - Clicking it shows a list of my event plans (if any) and a "New Event Plan" button
  - Creating a new plan opens a chat interface

**US-2: Describe an event in natural language**
As a chef, I want to type a description of my event (type, date, wines, covers, budget) in plain English so the system understands what I need.
- Acceptance Criteria:
  - Chat input accepts free-form text
  - System extracts: event type, date, cover count, budget per cover, and wine list
  - If key details are missing, the system asks follow-up questions

**US-3: Receive an AI-generated menu**
As a chef, I want to receive a multi-course menu paired to my wines so I have a creative starting point.
- Acceptance Criteria:
  - Each course includes: course name, dish name, dish description
  - Each wine includes: tasting notes and pairing rationale
  - Menu respects the cover count and budget constraints
  - Response appears in the chat within 30 seconds
  - A "thinking" indicator shows while the AI is working

### Epic: Wine Pairing

**US-4: View wine tasting notes**
As a chef, I want to see tasting notes for each wine so I understand the flavor profiles I'm pairing against.
- Acceptance Criteria:
  - Each wine in the menu shows: grape/blend, region, tasting notes (aroma, palate, finish)
  - Pairing rationale explains why the dish complements the wine

### Epic: Ingredient Costing

**US-5: See ingredients with quantities**
As a chef, I want to see a full ingredient list scaled to my cover count so I know exactly what to order.
- Acceptance Criteria:
  - Every dish breaks down into ingredients with quantities and units
  - Quantities are scaled to the specified cover count (e.g., 50 covers)
  - Common pantry staples are included (oil, salt, butter, etc.)

**US-6: See real supplier prices for ingredients**
As a chef, I want each ingredient matched to products in my connected supplier catalogs so I see real prices.
- Acceptance Criteria:
  - Ingredients are matched to SupplierProducts from the org's connected suppliers
  - Each matched ingredient shows: supplier name, product name, pack size, price
  - Unmatched ingredients are flagged as "not found in catalog"
  - If multiple suppliers carry an ingredient, the cheapest is highlighted

**US-7: See a cost breakdown**
As a chef, I want to see total cost, cost per cover, and comparison to my budget so I know if the menu is financially viable.
- Acceptance Criteria:
  - Displays: total ingredient cost, cost per cover, budget per cover, over/under budget amount
  - Per-course cost breakdown available
  - Unmatched ingredient costs are estimated by the AI and clearly marked as estimates

### Epic: Menu Refinement

**US-8: Refine the menu conversationally**
As a chef, I want to ask the AI to modify specific courses, swap ingredients, or adjust for dietary restrictions so I can iterate toward the perfect menu.
- Acceptance Criteria:
  - Chef can request changes in natural language (e.g., "swap the fish for something lighter", "make course 3 vegetarian", "find a cheaper alternative for the lamb")
  - The AI updates only the affected courses while preserving the rest
  - Costs are recalculated after each change
  - Full conversation history is visible in the chat

**US-9: Ask follow-up questions**
As a chef, I want to ask the AI questions about technique, substitutions, or wine pairing logic so I can learn and make informed decisions.
- Acceptance Criteria:
  - The AI answers general culinary questions within the context of the current menu plan
  - Questions don't disrupt the current menu state

### Epic: Order Creation

**US-10: Build an order from the finalized menu**
As a chef, I want to convert my finalized menu into purchase orders so I can order all ingredients from my suppliers.
- Acceptance Criteria:
  - "Build Order" button is visible when a menu with matched ingredients exists
  - Clicking it creates pending Order records grouped by supplier
  - Only ingredients with matched supplier products are included
  - Chef is redirected to the existing order review page
  - Unmatched ingredients are listed separately so the chef knows what to source manually

**US-11: Review and submit orders**
As a chef, I want to review the generated orders before submitting so I can adjust quantities or remove items.
- Acceptance Criteria:
  - Existing order review flow is used (no new UI needed)
  - Chef can modify quantities, remove items, or change suppliers before submitting
  - Orders are submitted through the existing order placement flow

### Epic: Plan Management

**US-12: View past event plans**
As a chef, I want to see a list of my past event plans so I can reference or reuse them.
- Acceptance Criteria:
  - Index page shows all plans for the current organization
  - Each plan shows: title, date, cover count, status (drafting/finalized/ordered), created date
  - Clicking a plan opens the chat with full conversation history

**US-13: Reuse a past menu**
As a chef, I want to reference a past event plan when creating a new one so I can adapt menus I've used before.
- Acceptance Criteria:
  - Chef can say "Use a similar menu to my Valentine's Day dinner but for 75 covers"
  - If the referenced plan exists, the AI uses it as a starting point (stretch goal — not required for MVP)

---

## 7. Functional Requirements

### FR-1: Natural Language Processing
- The system must extract structured event details from free-form text input
- Required fields: cover count, wine list (at minimum)
- Optional fields: event type, date, budget per cover, dietary restrictions
- If required fields are missing, the system must ask for them

### FR-2: Menu Generation
- Menus must include one course per wine (or a logical course structure if wines don't map 1:1)
- Each course must include: course name/number, dish name, description, ingredient list
- Generated dishes must be realistic, restaurant-quality, and appropriate for the event type
- The AI must consider: seasonal availability, cuisine coherence, dietary variety across courses

### FR-3: Wine Knowledge
- The system must generate accurate tasting notes for common wines
- Pairing rationale must reference specific flavor interactions (acid/fat, tannin/protein, etc.)
- For obscure or unknown wines, the system should indicate uncertainty

### FR-4: Ingredient Quantification
- Quantities must be scaled to the specified cover count
- Quantities must use standard restaurant units (lb, oz, each, bunch, qt, etc.)
- A reasonable waste/buffer factor should be included (10-15%)

### FR-5: Catalog Matching
- Ingredient matching must search across all suppliers connected to the chef's organization
- Matching must use fuzzy/normalized name matching (not just exact match)
- Results must include: supplier name, product name, pack size, unit price
- Match confidence should be indicated (exact match vs fuzzy match)

### FR-6: Cost Calculation
- Total ingredient cost must be calculated from real supplier prices
- Per-cover cost = total cost / cover count
- Budget variance = per-cover cost - budget per cover
- Unmatched ingredients must be estimated by the AI and clearly labeled

### FR-7: Conversation Persistence
- All messages must be persisted to the database
- Reopening a plan must show the full conversation history
- The AI must have access to the full conversation context for refinements

### FR-8: Order Creation
- Orders must be created as "pending" status (not auto-submitted)
- Orders must be grouped by supplier
- Order items must reference real SupplierProduct records
- The existing order review and submission flow must be reused

---

## 8. Non-Functional Requirements

### NFR-1: Performance
- AI response time: < 30 seconds for initial menu generation
- AI response time: < 15 seconds for refinements
- A visible "thinking" indicator must appear immediately after sending a message

### NFR-2: Cost
- OpenAI API costs should be monitored
- GPT-4o usage per menu plan estimated at $0.05-0.15 (input + output tokens)
- No per-plan limit for the prototype; consider limits for production

### NFR-3: Multi-Tenancy
- Event plans scoped to the user's current organization
- Catalog search scoped to suppliers connected to the organization
- Other organization members should not see each other's plans (for MVP)

### NFR-4: Error Handling
- OpenAI API failures must show a user-friendly error in the chat
- Catalog search failures must not block menu generation (show menu without pricing)
- Network errors during message submission must be handled gracefully

### NFR-5: Mobile Responsiveness
- The chat interface must be usable on tablet and mobile devices
- Message bubbles must wrap properly on small screens
- The input area must remain accessible (fixed at bottom)

---

## 9. Out of Scope (for MVP)

- Real-time wine API integration (Vivino, Wine-Searcher)
- Recipe instructions or cooking methods (menu focuses on dish names + ingredients)
- Dietary restriction database or allergen tracking
- Menu PDF export or printing
- Sharing plans with team members
- Template library of pre-built menus
- Integration with reservation systems for cover count
- Actual recipe yield calculations (AI estimates quantities)
- Photo generation for dishes

---

## 10. Data Model Summary

| Entity | Key Fields | Relationships |
|--------|-----------|---------------|
| EventPlan | title, status, event_details (JSONB), current_menu (JSONB) | belongs_to User, Organization; has_many Messages |
| EventPlanMessage | role, content, structured_data (JSONB), status | belongs_to EventPlan |

The `current_menu` JSONB stores the latest structured menu including courses, ingredients, supplier matches, and cost calculations. This avoids needing separate course/ingredient tables for the prototype while keeping the data queryable.

---

## 11. Dependencies

| Dependency | Status | Notes |
|-----------|--------|-------|
| OpenAI API key (OPENAI_API_KEY) | Already configured | Used by AiProductCategorizer |
| Supplier catalog data | Already exists | Products imported by daily cron job |
| Solid Cable (ActionCable) | Already configured | Used by TwoFactorChannel |
| ProductNormalizer service | Already exists | Reuse for ingredient matching |
| Order creation flow | Already exists | Reuse AggregatedListOrderService pattern |

---

## 12. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| GPT-4o generates unrealistic quantities | Chef orders wrong amounts | Include disclaimer: "AI-estimated quantities — review before ordering" |
| Ingredient names don't match supplier catalog | Low match rate, inaccurate costs | Use fuzzy matching + AI fallback; show unmatched items clearly |
| OpenAI API latency spikes | Poor user experience | Background job + thinking indicator; timeout after 60s with error message |
| Hallucinated wine information | Incorrect pairings | Target well-known wines first; add disclaimer for obscure wines |
| Budget calculations inaccurate due to pack sizes | Chef over-orders | Show pack size context ("you need 5 lb but minimum pack is 10 lb case") |

---

## 13. Success Criteria

For the prototype to be considered successful:

1. A chef can go from a natural-language event description to a complete wine-paired menu in under 2 minutes
2. At least 70% of menu ingredients match to real supplier products
3. Cost calculations are within 20% of what the chef would calculate manually
4. The chef can refine the menu through 3+ conversational turns without context loss
5. The "Build Order" flow creates valid, submittable orders through the existing pipeline
