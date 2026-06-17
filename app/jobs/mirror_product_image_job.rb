# frozen_string_literal: true

require "vips"

# Lazily mirror a supplier's product image into our own storage as a small
# thumbnail (PRD: Product Image Thumbnails, Phase 2).
#
# - Downloads image_source_url, resizes to a ~200px JPEG, attaches it to the
#   SupplierProduct, and marks image_status = "mirrored".
# - Deduped per product via limits_concurrency (once per product, ever) so a
#   popular product viewed by many chefs only fetches once.
# - Non-image / unreachable sources are negative-cached (status "none"/"failed"
#   + image_checked_at) so we don't refetch on every view.
class MirrorProductImageJob < ApplicationJob
  queue_as :low

  # Only one in-flight mirror per product; key matches the existing PlaceOrderJob
  # concurrency pattern.
  limits_concurrency to: 1, key: ->(supplier_product_id, *) { "mirror_image_#{supplier_product_id}" }, duration: 10.minutes

  THUMB_PX = 200
  JPEG_QUALITY = 72

  def perform(supplier_product_id)
    sp = SupplierProduct.find_by(id: supplier_product_id)
    return if sp.nil? || sp.thumbnail.attached? || sp.image_source_url.blank?

    result, body, content_type = download(sp.image_source_url)
    return mark(sp, "failed") if result == :failed # transient (network) — retried sooner
    return mark(sp, "none") if result == :none || !content_type.to_s.start_with?("image/")

    thumb = resize(body)
    return mark(sp, "failed") if thumb.nil?

    sp.thumbnail.attach(io: thumb, filename: "sp-#{sp.id}.jpg", content_type: "image/jpeg")
    mark(sp, "mirrored")
  end

  private

  # Returns [:ok, body, content_type] | [:none, nil, nil] (4xx/5xx) |
  # [:failed, nil, nil] (transient network error).
  def download(url)
    resp = Faraday.get(url) do |req|
      req.options.timeout = 12
      req.options.open_timeout = 8
      req.headers["User-Agent"] = "Mozilla/5.0 (compatible; EnPlaceImageBot/1.0)"
    end
    return [:none, nil, nil] unless resp.success?

    [:ok, resp.body, resp.headers["content-type"]]
  rescue Faraday::Error, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
    Rails.logger.warn("[MirrorProductImageJob] download failed for #{url}: #{e.class}: #{e.message}")
    [:failed, nil, nil]
  end

  # Resize from in-memory bytes to a JPEG thumbnail. Uses libvips' fast
  # thumbnailer (no upscaling). Returns a StringIO of JPEG bytes, or nil.
  def resize(body)
    image = Vips::Image.thumbnail_buffer(body, THUMB_PX, height: THUMB_PX, size: :down)
    StringIO.new(image.jpegsave_buffer(Q: JPEG_QUALITY, strip: true))
  rescue Vips::Error, StandardError => e
    Rails.logger.warn("[MirrorProductImageJob] resize failed: #{e.class}: #{e.message}")
    nil
  end

  def mark(supplier_product, status)
    supplier_product.update!(image_status: status, image_checked_at: Time.current)
  end
end
