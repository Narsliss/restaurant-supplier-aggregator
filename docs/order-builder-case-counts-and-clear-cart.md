# Order builder: case counts, Clear cart, fresh delivery date (Sep 27 2026)

## Why
While building the first Performance order, Carmin said: "I have no idea how many items from performance I have in my cart currently … I had items from PPO and US foods already in the cart … there needs to be some sort of clear cart button". Her screenshot showed three more problems:
- Performance's chip said "No minimum", although a 20-case minimum had just been set.
- The delivery date was 08/26/2026, a month in the past, restored from the saved cart.
- Create Orders was greyed out because of that past date.

## What changed
- **Case counts in each supplier chip** (desktop bar, both layouts) via `aggregated_lists/_supplier_case_count`: "6 cases", or "6 / 20 cases" against a case minimum, orange until met and then green. It counts like the review page (`Order#item_count`, every unit ordered). `order_builder_controller#_updateCaseCounts` updates it from each row's new `perSupplierQty`. "No minimum" now shows only when a supplier has neither a dollar nor a case minimum.
- **Phone ribbon pills** show the same count, and a case minimum counts toward "min met" (`caseMinimums` value). The phone already had a Clear button.
- **Clear cart** (desktop bar) asks for confirmation, empties every line, and saves the empty working order (CurrentOrder). Orders already created aren't touched; it deliberately does not call `DELETE /current_order`, which also deletes draft batches. The bar is a clone outside the controller's element, so the button is wired by hand in `_setupFixedUI`.
- **Minimums follow the restaurant being ordered for.** `@supplier_minimums` now uses `SupplierRequirement.effective_for(location: current_location)` and adds `case_minimum` (`Supplier#case_minimum`). Previously it took an arbitrary active `order_minimum` row per supplier, which could be another restaurant's.
- **An expired saved delivery date isn't restored.** The field comes back blank, so the chef picks a date instead of facing a disabled button.
- **Data:** the Performance supplier-wide case minimum was set to 20 on production (a `supplier_requirements` row with `location_id` nil, blocking), with the same message template as the other case minimums.

## Verified
- `spec/requests/order_builder_bar_spec.rb` (6 examples). Full suite 1,514.
- In the dev browser, with the dev chef's real saved cart (dated Aug 27): the date came back blank; the chips read "7 / 5 cases" (green) and "4 / 5 cases" (orange); Clear cart asked, emptied every line and saved an empty cart. That dev cart was backed up and restored afterwards.

## Not changed
- How orders are placed. The review page still enforces minimums.
