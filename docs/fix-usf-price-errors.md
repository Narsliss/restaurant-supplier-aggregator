# Fix: US Foods "$0" prices were error responses

**Date:** 2026-09-25 · **Status:** built, full suite green (1,366 examples), not yet deployed · **Order placement:** untouched

## What we found

On Sep 25, **6,694 of 14,962** active US Foods catalog products showed `current_price = 0.00`, and so did 151 items on chefs' US Foods lists.
- The earlier belief was that $0 meant "in catalog, no contract price". That came from a code comment in `refresh_batch`, which I repeated to Carmin as fact. **It was wrong.**
- A read-only query of US Foods' pricing API, using the existing session of credential 90, returned an error with every "0" we checked. 13 of 13 zero-priced SKUs came back with one of these, with `unitPrice` set to "0":

  | errorNumber | Message | Meaning |
  |---|---|---|
  | 1104 | PRODUCT ERROR - DISCONTINUED PRODUCT | Gone for everyone. The product API shows `productStatus` "9" and a `statusChangeDate` matching the day our price dropped (heirloom tomato: discontinued Sep 9, our price went to $0 on Sep 10). |
  | 1102 | PRODUCT ERROR - DOES NOT EXIST | Gone for everyone |
  | 1106 | PRODUCT ERROR - PRODUCT IS PROPRIETARY | Reserved for other customers; unavailable to this account |

- `UsFoodsApi#fetch_prices` ignored `errorNumber`, so every consumer stored the "0" as a price. The May 25 `refresh_known_skus` change wrote it on purpose, which is behind the 3,780 products set to $0 on May 26.
- **The builder showed these as orderable $0.00 cells.** The desktop view checks `if effective_price`, and 0 is truthy; the mobile view checks `.blank?`, which 0 isn't.
- The gloves (7821499) were the one exception: they had a real $54.29 price, and our copy was simply stale.

## The fix

- **`UsFoodsApi#fetch_prices`** adds `error_number` and `error_message`. This is additive only: `case_price`, `split_price` and `price_uom` are unchanged, and the order price-verification path (`scrape_prices`) is untouched.
- **`UsFoodsScraper.price_error(price)`** returns `:discontinued` for 1102 and 1104, `:unavailable` for any other non-zero error, and `nil` when the price is real.
- **Catalog walk and order-guide sync (`format_list_item`):** on an error, no price is stored (`nil`), not 0.
- **`refresh_known_skus`:** on an error, the SKU is still treated as seen, but its update carries `current_price: nil, unavailable: true, discontinued: <bool>`.
- **`ImportSupplierProductsService#apply_refresh_updates`:**
  - For an unavailable product, it clears the product's price and keeps the last real price as `previous_price`.
  - For a discontinued product, it also sets `discontinued`, and clears the price on every linked list item. That removes the orderable $0.00 cell.
  - A **1106 (proprietary)** product clears only the catalog price. The catalog imports under our own account, and a chef's own account may still be able to buy the item; their list sync decides that.
- **Builder:** the empty cell now says **"Discontinued"** (desktop) or shows a "Discontinued" chip (mobile) when the product is discontinued, instead of "No price" or "N/A". The item stays in the chef's row, following the protection rule.
- Carmin decided **not** to suggest replacements, even though US Foods provides `replacementProductNumber`. It would make chefs come back and confirm a swap.

## Existing data

Nothing is backfilled by hand. The next daily US Foods catalog import runs `refresh_known_products`, which re-asks US Foods about every non-discontinued SKU, including all 6,694 zero-priced ones, and corrects them. The 8 AM UTC list sync then corrects the chefs' guide items.

## Tests

- `spec/services/scrapers/us_foods_scraper_spec.rb`:
  - The old test "counts $0 prices as updates so no-contract items stay seen" encoded the wrong assumption. It is replaced with tests for:
    - 1104, which is priceless and discontinued;
    - 1106, which is priceless but not discontinued;
    - a real price with no error, which passes through unchanged.
  - `.price_error` is tested directly.
  - `format_list_item` stores no price on an error and keeps real prices.
- `spec/services/scrapers/us_foods_api_spec.rb`: `fetch_prices` keeps the price fields unchanged and adds the error.
- `spec/services/import_supplier_products_service_spec.rb`:
  - a discontinued product is marked and its price cleared everywhere;
  - a proprietary product has only its catalog price cleared;
  - an ordinary price update is unchanged.
- `spec/requests/order_builder_discontinued_spec.rb`: the builder labels the cell "Discontinued" and offers no orderable cell for that supplier, on desktop and mobile.

## Open items

- **Chef's Warehouse:** 13,309 of 15,483 catalog products have never had a price. That is a separate issue, since the catalog browse likely has no account pricing, and it has not been investigated.
- **Sysco:** 3,104 unpriced products. Not investigated.
