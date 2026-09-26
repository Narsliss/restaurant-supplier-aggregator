# Takes a supplier out of matched rows — the ONE path that does, used when a
# chef removes a supplier connection or a supplier is deleted. Everything else
# is refused by the database (supplier list items a row uses can't be deleted).
#
# Each removed item is recorded (MatchItemRemoval, with the given cause). A row
# left with nothing in it is deleted too — an all-"No match" row helps nobody —
# unless a chef's order list or saved cart still points at it; those stay so
# nothing a chef built silently loses its line (MatchHealthCheckJob reports them).
class MatchedListSupplierRemoval
  def initialize(match_items, cause:)
    @match_items = match_items
    @cause = cause
  end

  def call
    MatchChange.as(@cause) do
      rows = ProductMatch.where(id: @match_items.select(:product_match_id)).to_a
      removed = 0
      @match_items.find_each do |pmi|
        pmi.destroy!
        removed += 1
      end

      emptied = rows.select { |row| row.product_match_items.reload.empty? }
      deleted = emptied.reject { |row| referenced?(row) }
      deleted.each(&:destroy!)

      Rails.logger.info "[MatchedListSupplierRemoval] #{@cause}: removed #{removed} items, " \
                        "deleted #{deleted.size} emptied rows, kept #{emptied.size - deleted.size} still referenced"
      { removed_items: removed, deleted_rows: deleted.size, kept_empty_rows: emptied.size - deleted.size }
    end
  end

  private

  def referenced?(row)
    OrderListItem.where(product_match_id: row.id).exists? ||
      CurrentOrder.where(aggregated_list_id: row.aggregated_list_id)
                  .where('state ? :key', key: row.id.to_s).exists?
  end
end
