# PRD: Product Image Thumbnails

- **Status:** Draft / awaiting approval to implement
- **Date:** 2026-06-17
- **Owner:** CJ Moutinho
- **Related memory:** `reference_supplier_product_images.md`

---

## 1. Summary

Mirror a small thumbnail per `SupplierProduct` to our own object storage so we can show product images without depending on supplier CDNs. All five suppliers expose an image URL through API responses we already make. We will **capture the URL at import**, then **lazily mirror a small thumbnail on first view**, deduped once-per-product, and serve it from our storage forever after. No runtime browser, no full-catalog crawl, minimal cost, minimal supplier contact.

**Scope note:** this PRD is the *infrastructure* layer only — it produces `supplier_product.thumbnail`. The primary consumer is the **matching modal** (see PRD 2 — Matching Page Redesign & Canonical Items), which displays a thumbnail for the primary item + each selected candidate, and lets the chef pick one as the **canonical image**. The canonical-image feature itself (a `ProductMatch`-level, user-picked image shown in order lists/cart) is specified in **PRD 2**; this PRD just supplies the thumbnails PRD 2 picks from.

---

## 2. Background & discovery findings

Investigation (2026-06-17, live-probed on production) established that **every supplier returns a usable image URL via an API call we already issue** — for two of them (WCW, PPO) the field was found by capturing the live web app's network traffic with the existing headless-browser scraper, then confirmed reachable over plain HTTP.

### Per-supplier image source (the only new code in the data layer)

| Supplier | Field | Query (already called) | Confirmed coverage |
|---|---|---|---|
| US Foods | `summary.productAssets.productImages.{C1CC,A1CF}.renditions.{Thumbnail,Small,Medium…}` | `product-domain-api/v2/products` | high (assets present on probed items) |
| Sysco | `productInfo.images[]` | `SearchProducts` GraphQL (already requests `images`) | high |
| Chef's Warehouse | `imageUrl` | order guide (already parsed) + search | high |
| What Chefs Want | `canonicalproduct { thumbnail { url } }` | `formForOrder` + `catalogProductsSearchRootQuery` | **100%** sampled (120/120 + 183/183) |
| PPO / Pepper | `item { photo_url_list[] }` | `Catalog_VariantPackGroupItems` | **99.2%** (2400/2419) |

All sampled URLs returned HTTP 200 with real image bytes. The URLs are full and public (no auth, no hotlink protection on any CDN).

### Catalog scale (active, non-discontinued products on prod)

| Supplier | Active products |
|---|---|
| Sysco | 27,812 |
| US Foods | 14,504 |
| Chef's Warehouse | 4,997 |
| What Chefs Want | 3,466 |
| PPO | 2,372 |
| **Total** | **~53,151** |

### Observed image sizes (originals)
USF thumb 2.4 KB / med 11 KB / xl 31 KB · Sysco 57 KB · CW 154 KB · WCW 16 KB · PPO 67 KB. Wide spread → we resize on ingest rather than store originals.

---

## 3. Goals / Non-goals

### Goals
- Display a small thumbnail for products across all five suppliers.
- Decouple from supplier CDNs: serve images from our own storage.
- Minimal cost (target: within R2 free tier), minimal supplier footprint, no ordering-path risk.
- Grow storage organically with actual usage (lazy), not by crawling the whole catalog.

### Non-goals
- No full-resolution / zoomable product imagery (thumbnails only).
- No monthly bulk crawl (superseded by lazy fetch).
- No runtime headless browser (discovery already done; runtime is pure HTTP).
- No image hosting for products never viewed.
- No thumbnails in a full catalog-browse grid in v1 — the only consumer is the matching modal (small, on-demand set). This is what keeps lazy fetching cheap and burst-free.
- The canonical image (ProductMatch-level, user-picked, shown in order lists/cart) is **out of scope here** — it lives in PRD 2.

---

## 4. Storage decision (cost-driven)

**Chosen: Cloudflare R2 via Active Storage, storing a single pre-resized thumbnail per product.**

### Why R2
| Option | Persists on Railway? | Cost | Verdict |
|---|---|---|---|
| Container local disk | ❌ wiped every deploy | — | unusable |
| Postgres `bytea` | ✅ | bloats DB/backups/memory | rejected |
| Railway Volume | ✅ | ~$0.25/GB-mo + can't share across web/worker | awkward topology |
| AWS S3 | ✅ | $0.023/GB + **egress $0.09/GB** | egress cost on every view |
| **Cloudflare R2** | ✅ | **$0.015/GB-mo, $0 egress; free tier 10 GB / 1M writes / 10M reads** | **chosen** |

### Capacity
Thumbnails (~200px, JPEG q~72) ≈ **~8 KB each**. Lazy ⇒ only viewed products get stored (hundreds–low thousands, not 53k). Realistic store **tens of MB**, almost certainly **$0/mo (inside R2 free tier)**. Even if every active product were eventually mirrored: 53k × 8 KB ≈ **~425 MB** — still inside the free tier.

### Mechanism
- Active Storage with an S3-compatible service pointed at R2, `public: true` → public CDN-backed URLs, **no Rails proxying** of image bytes.
- We **resize on ingest and store only the thumbnail** (discard the original) — smallest footprint, no variant machinery needed at serve time.

---

## 5. Data model

### Migration
```ruby
add_column :supplier_products, :image_source_url, :string       # supplier CDN URL captured at import
add_column :supplier_products, :image_status,     :string, default: "unknown"
                                                                # unknown | pending | mirrored | none | failed
add_column :supplier_products, :image_checked_at, :datetime     # negative-cache timestamp
add_index  :supplier_products, :image_status
```
```ruby
class SupplierProduct < ApplicationRecord
  has_one_attached :thumbnail   # the mirrored ~200px JPEG (only the thumbnail is stored)
end
```
Plus `bin/rails active_storage:install` (blobs/attachments). With lazy mirroring these tables hold only viewed products.

### Status lifecycle
- `unknown` — never imported with image info yet.
- `pending` — have `image_source_url`, not yet mirrored.
- `mirrored` — thumbnail attached in R2.
- `none` — no URL, or source returned non-image / 404.
- `failed` — transient error; eligible for retry after TTL.

---

## 6. Phase 1 — Capture URLs (no storage, no UI)

**Outcome:** every product gets `image_source_url` on the next catalog import; measure real coverage before building storage.

1. Run the migration (columns only; `thumbnail` attachment unused yet).
2. **Five parser changes** — add the field to the item hash each scraper emits:
   - **US Foods** — `us_foods_scraper.rb#scrape_catalog`: `image_url:` ← a rendition URL from `summary.productAssets.productImages`. *(Verify the v2 node in scrape_catalog carries `summary.productAssets`; it did in the probe.)*
   - **Sysco** — `sysco_scraper.rb#parse_search_result`: `image_url: (info["images"] || []).first`.
   - **Chef's Warehouse** — `chefs_warehouse_api.rb#parse_order_guide_item` already builds `image_url`; add the same to `parse_search_product`; thread through `scrape_catalog`.
   - **What Chefs Want** — `what_chefs_want_api.rb`: add `thumbnail { url }` to `search_products_query`, `browse_category_query`, `form_for_order_query`; parse `cp.dig("thumbnail","url")`.
   - **PPO** — `premiere_produce_one_api.rb`: add `photo_url_list` to `item {}` in `CATALOG_QUERY` (+ `ORDER_GUIDE_QUERY`, `SEARCH_QUERY`); parse `(item["photo_url_list"] || []).first`.
3. **Persist in the import sink** — `import_supplier_products_service.rb`:
   - `import_new_item` and the update path set `image_source_url` and `image_status` (`pending` if a URL exists, else `none`).
   - On update, if the URL changed → reset `image_status: "pending"` and detach any existing thumbnail (re-mirror).

**Exit criteria:** run an import; coverage report per supplier matches discovery (~99–100% for PPO/WCW/Sysco). Invisible to users.

---

## 7. Phase 2 — Lazy mirroring + serving

### Dependencies / config
- Gems: `aws-sdk-s3`, `image_processing`.
- Docker: add `libvips` (resizing).
- `config/storage.yml` service `cloudflare` (S3 adapter, R2 endpoint, `public: true`).
- `production.rb`: `config.active_storage.service = :cloudflare`.
- Railway env: `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`.
- Feature flag: `PRODUCT_IMAGES_ENABLED` (gates mirroring + serving).

### Mirror job
```ruby
class MirrorProductImageJob < ApplicationJob
  queue_as :low
  limits_concurrency key: ->(sp) { "mirror-img-#{sp.id}" }   # dedup: once per product, ever

  def perform(sp)
    return if sp.thumbnail.attached? || sp.image_source_url.blank?
    resp = http_get(sp.image_source_url, timeout: 10)        # anonymous GET, realistic UA, backoff
    unless resp.success? && resp.content_type.to_s.start_with?("image/")
      return sp.update!(image_status: "none", image_checked_at: Time.current)  # negative cache
    end
    thumb = ImageProcessing::Vips
              .source(StringIO.new(resp.body))
              .resize_to_limit(200, 200)
              .convert("jpg").saver(quality: 72).call          # ~8 KB
    sp.thumbnail.attach(io: thumb, filename: "#{sp.id}.jpg", content_type: "image/jpeg")
    sp.update!(image_status: "mirrored", image_checked_at: Time.current)
  rescue => e
    sp.update!(image_status: "failed", image_checked_at: Time.current)
  end
end
```
- **Dedup:** `limits_concurrency` keyed on `sp.id` (same pattern as `PlaceOrderJob`) → no thundering herd if many chefs open the same product before the first fetch finishes.
- **Negative cache:** `none`/`failed` + recent `image_checked_at` ⇒ skip refetch on every view.
- **Throttle/backoff** in `http_get` keeps supplier contact gentle.

### Serving (helper)
```ruby
def product_thumb_url(sp)
  return rails_storage_proxy_or_public_url(sp.thumbnail) if sp.thumbnail.attached?
  if sp.image_status == "pending" ||
     (sp.image_status.in?(%w[none failed]) && sp.image_checked_at&.before?(60.days.ago))
    MirrorProductImageJob.perform_later(sp)   # deduped; fire-and-forget
  end
  placeholder_image_url
end
```
- First view → placeholder + enqueue; thumbnail appears next render (optionally a Turbo Stream swap for live pop-in).
- **Warm-up (matching modal):** when a matching modal opens, enqueue mirror jobs for the primary item + the matched/candidate items so thumbnails are ready as the chef picks. This is the natural — and only — warm-up surface in v1.

---

## 8. Phase 3 — UI (consumed by PRD 2)
- Expose `product_thumb_url(sp)` for the matching modal to render the primary + candidate thumbnails. The modal UI, the canonical-image picker, and order-list/cart display all live in **PRD 2**.
- Use standard light-mode Tailwind classes; dark mode handled by existing CSS overrides (per project convention).
- Tasteful placeholder for `none`.

---

## 9. Safety

- **Ordering untouched.** All changes are catalog/search/display: parser fields, a migration, a job, a helper. Nothing touches `OrderPlacementService`, cart, `add_to_cart`, or submit. The WCW `form_for_order_query` is a read (order-guide listing) query — re-verify the added `thumbnail` field does not perturb the order-guide sync before merge.
- **Detection footprint** (verified): no hotlink protection on any CDN; mirror GETs are anonymous (no auth, not tied to a chef account); one fetch per product, ever; throttle/backoff in the job. Lower profile than hotlinking, which would tag our domain in supplier logs on every user view.
- **ToS / copyright:** mirroring supplier imagery is the more exposed legal posture (vs. hotlinking) — a business decision, flagged, not a technical blocker.

---

## 10. Testing (per project rule: tests alongside new behavior)
- Parser spec per supplier: fixture JSON → asserts `item[:image_url]` populated.
- `MirrorProductImageJob`: stubbed download → attaches + `mirrored`; non-image/404 → `none`; error → `failed`; dedup no-ops while attached; produces a ~200px JPEG.
- Helper: attached → URL; `pending` → enqueues + placeholder; negative-cache respects TTL.
- Import service: `image_source_url` set on create; re-`pending` + detach on URL change.

---

## 11. Rollout
1. **Phase 1** — capture only (invisible). Measure coverage.
2. **Phase 2** — R2 + Active Storage + job + helper behind `PRODUCT_IMAGES_ENABLED`.
3. **Phase 3** — flip UI on once thumbnails look right on a real catalog.

---

## 12. Cost & capacity summary
- Per thumbnail ≈ 8 KB. Lazy store ≈ tens of MB (likely **$0/mo, inside R2 free tier**). Worst case (all 53k) ≈ 425 MB, still free-tier.
- Compute: one resize per product, once; process one at a time → flat memory.

---

## 13. Risks & open questions
- **USF rendition availability in `scrape_catalog`** — confirm the v2 node used by the import carries `summary.productAssets` (probe showed it does; verify in the import path specifically).
- **CW search `imageUrl`** — confirm catalog-search nodes carry `imageUrl` (order-guide nodes do).
- **WCW field in order vs. catalog** — `thumbnail.url` confirmed populated in both `formForOrder` and search; keep both.
- **Expiring/signed URLs** — none observed, but storing the file (not the URL) insulates us if a supplier later signs URLs.
- **Selector/field drift** — supplier schema changes could empty a field; coverage monitoring (below) catches it.

---

## 14. Success metrics
- ≥ 95% of viewed products render a real thumbnail within one render cycle of first view.
- R2 spend remains $0 (free tier) for the foreseeable catalog.
- Zero ordering-path regressions.
- Image-fetch error rate (`failed`/`none` among products with a non-blank source URL) < 2%.
