# Set Weight: a chef supplying the pack weight their supplier never gave.
#
# The request names a supplier list item and a weight, nothing else. Every
# identifying field — organization, location, supplier, SKU, and the pack
# string the weight is pinned to — is derived here from that item, so a
# forged request cannot write a weight into another group's list.
class UnitOverridesController < ApplicationController
  before_action :set_item
  before_action :require_write_access!

  def create
    oz = ounces_from_params
    return reject("Enter a weight greater than zero.") unless oz&.positive?

    total = total_oz_for_preview(oz)
    return reject("That weight doesn't look right for this pack — check the number.") unless plausible?(total)

    override = UnitOverride.find_or_initialize_by(
      organization_id: @item.supplier_list.organization_id,
      location_id: @item.supplier_list.location_id,
      supplier_id: @item.supplier_list.supplier_id,
      supplier_sku: sku
    )
    override.assign_attributes(
      basis: basis,
      net_weight_oz: oz,
      # Pinned to the pack it was entered against. When the supplier changes
      # the pack, this is what tells us the weight no longer describes the box.
      pack_size_fingerprint: pack_size,
      price_at_entry: @item.price,
      created_by_user: current_user,
      note: params[:note].presence,
      confirmed_at: Time.current
    )

    if override.save
      redirect_back fallback_location: root_path, notice: "Weight saved for #{@item.name}."
    else
      reject(override.errors.full_messages.to_sentence)
    end
  end

  def destroy
    UnitOverride.where(organization_id: @item.supplier_list.organization_id,
                       location_id: @item.supplier_list.location_id,
                       supplier_id: @item.supplier_list.supplier_id,
                       supplier_sku: sku).destroy_all

    redirect_back fallback_location: root_path, notice: "Weight removed for #{@item.name}."
  end

  private

  def set_item
    @item = SupplierListItem.includes(:supplier_product, :supplier_list)
                            .find(params[:supplier_list_item_id])
  end

  # Any chef or owner may set or correct any weight in their own group: the
  # person who spots a wrong number is the person who should be able to fix it,
  # and locking it to whoever typed it first leaves a bad weight standing until
  # an owner intervenes. Managers create nothing anywhere in the app.
  def require_write_access!
    org = @item.supplier_list.organization_id
    unless org.present? && org == current_user.current_organization&.id && (current_user.super_admin? || operator?)
      redirect_back fallback_location: root_path, alert: "You don't have permission to set weights on this list."
    end
  end

  def sku
    @item.sku.presence || @item.supplier_product&.supplier_sku
  end

  def pack_size
    @item.pack_size.presence || @item.supplier_product&.pack_size
  end

  def basis
    UnitOverride::BASES.include?(params[:basis]) ? params[:basis] : "per_pack"
  end

  # Chefs think in pounds; the comparison works in ounces.
  def ounces_from_params
    weight = params[:weight].to_f
    return nil unless weight.positive?

    case params[:unit].to_s.downcase
    when "oz" then weight
    when "kg" then weight * 35.274
    else weight * 16.0
    end
  end

  def total_oz_for_preview(oz)
    UnitOverride.new(basis: basis, net_weight_oz: oz).total_oz_for(pack_size)
  end

  # Catches a price that is unarguably wrong. It cannot catch a ten-fold slip
  # that still lands on a believable number — that is what the preview beside
  # the other suppliers' prices is for.
  def plausible?(total_oz)
    return false if total_oz.blank?
    return true if @item.price.blank? || !@item.price.positive?

    UnitOverride.plausible_per_lb?(@item.price, total_oz)
  end

  def reject(message)
    redirect_back fallback_location: root_path, alert: message
  end
end
