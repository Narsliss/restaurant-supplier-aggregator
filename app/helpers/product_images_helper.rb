# frozen_string_literal: true

# Serving + lazy-trigger for mirrored product thumbnails
# (PRD: Product Image Thumbnails, Phase 2).
module ProductImagesHelper
  # Inline light-gray placeholder so callers never need a static asset.
  PRODUCT_IMAGE_PLACEHOLDER =
    "data:image/svg+xml;utf8," \
    "<svg xmlns='http://www.w3.org/2000/svg' width='80' height='80'>" \
    "<rect width='80' height='80' fill='%23f3f4f6'/>" \
    "<path d='M20 54l14-16 10 11 8-8 8 13z' fill='%23d1d5db'/>" \
    "<circle cx='30' cy='30' r='6' fill='%23d1d5db'/></svg>"

  # Confirmed "no image" waits a long time before re-checking; transient
  # failures retry the next day.
  NONE_TTL = 60.days
  FAILED_TTL = 1.day

  # Returns a served thumbnail URL for a SupplierProduct, or a placeholder.
  # On a miss (have a source URL but not mirrored), enqueues the lazy mirror job.
  def product_thumb_url(supplier_product)
    return PRODUCT_IMAGE_PLACEHOLDER if supplier_product.blank?

    if supplier_product.thumbnail.attached?
      r2_public_url(supplier_product.thumbnail.key) || PRODUCT_IMAGE_PLACEHOLDER
    else
      enqueue_mirror_if_due(supplier_product)
      PRODUCT_IMAGE_PLACEHOLDER
    end
  end

  private

  # Objects are served through the bucket's custom domain at /<key>.
  def r2_public_url(key)
    host = ENV["R2_PUBLIC_HOST"]
    host.present? ? "https://#{host}/#{key}" : nil
  end

  def enqueue_mirror_if_due(sp)
    return unless product_images_enabled?
    return if sp.image_source_url.blank?

    due =
      case sp.image_status
      when "pending"
        true
      when "failed"
        sp.image_checked_at.nil? || sp.image_checked_at < FAILED_TTL.ago
      when "none"
        sp.image_checked_at.nil? || sp.image_checked_at < NONE_TTL.ago
      else
        false
      end

    MirrorProductImageJob.perform_later(sp.id) if due
  end

  def product_images_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV["PRODUCT_IMAGES_ENABLED"])
  end
end
