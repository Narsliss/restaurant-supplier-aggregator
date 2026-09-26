class ProductMatchItem < ApplicationRecord
  # Associations
  belongs_to :product_match
  belongs_to :supplier_list_item
  belongs_to :supplier

  # Validations
  validates :supplier_id, uniqueness: {
    scope: :product_match_id,
    message: 'already has an item in this match'
  }

  # Delegations
  delegate :name, :sku, :price, :pack_size, :in_stock, :formatted_price, to: :supplier_list_item
  delegate :aggregated_list, to: :product_match

  # Every item that leaves a matched row leaves a record of what it was and
  # what removed it, so lost matching work can always be rebuilt.
  after_destroy :record_removal

  private

  def record_removal
    cause = MatchChange.cause ||
            (destroyed_by_association&.active_record == ProductMatch ? 'row_deleted' : 'unspecified')
    return if cause == 'organization_deleted' # everything goes; nothing to rebuild

    row = ProductMatch.find_by(id: product_match_id)
    sli = SupplierListItem.find_by(id: supplier_list_item_id)
    # Its own savepoint: failing to write the record must never undo the action.
    MatchItemRemoval.transaction(requires_new: true) do
      MatchItemRemoval.create!(
        organization_id: row&.aggregated_list&.organization_id,
        aggregated_list_id: row&.aggregated_list_id,
        product_match_id: product_match_id,
        row_name: row&.canonical_name.to_s.truncate(255),
        row_status: row&.match_status,
        supplier_id: supplier_id,
        supplier_list_id: sli&.supplier_list_id,
        supplier_list_item_id: supplier_list_item_id,
        supplier_product_id: sli&.supplier_product_id,
        sku: sli&.sku,
        item_name: sli&.name.to_s.truncate(255),
        cause: cause,
        user_id: MatchChange.user&.id
      )
    end
  rescue StandardError => e
    Rails.logger.error "[MatchItemRemoval] Could not record removal of item #{id}: #{e.class} #{e.message}"
  end
end
