class AggregatedListMapping < ApplicationRecord
  # Associations
  belongs_to :aggregated_list
  belongs_to :supplier_list

  # Validations
  validates :supplier_list_id, uniqueness: { scope: :aggregated_list_id }

  # Ensure we don't map two lists from the same supplier to one aggregated list
  validate :one_list_per_supplier

  private

  def one_list_per_supplier
    return unless aggregated_list && supplier_list

    existing = aggregated_list.aggregated_list_mappings
                              .joins(:supplier_list)
                              .where(supplier_lists: { supplier_id: supplier_list.supplier_id })
                              .where.not(id: id)

    return unless existing.exists?

    errors.add(:supplier_list, 'already has a list from this supplier in the aggregated list')
  end
end
