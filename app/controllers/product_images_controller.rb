# frozen_string_literal: true

# Lets the matching modal poll for thumbnails that have finished mirroring
# (the mirror runs async on the worker, so the first modal render shows
# placeholders). Returns served URLs ONLY for products whose thumbnail is
# already attached — it never enqueues a mirror, so it can't trigger supplier
# fetches.
class ProductImagesController < ApplicationController
  # JSON polling endpoint; skip the onboarding/subscription/salesperson redirects
  # that would otherwise turn a fetch() into a 302.
  skip_before_action :ensure_onboarding_complete, :require_subscription,
                     :redirect_salesperson_to_crm, raise: false

  # GET /product_images/resolve?ids=1,2,3
  # => { "1" => "https://images.../key.jpg", "3" => "https://..." }
  # Only mirrored products appear in the response.
  def resolve
    ids = params[:ids].to_s.split(",").map(&:to_i).reject(&:zero?).uniq.first(60)
    result = {}

    if ids.any?
      SupplierProduct.where(id: ids).with_attached_thumbnail.find_each do |sp|
        url = helpers.product_thumb_url(sp) # display-only (mirror: false) — no enqueue
        result[sp.id] = url unless url.start_with?("data:")
      end
    end

    render json: result
  end
end
