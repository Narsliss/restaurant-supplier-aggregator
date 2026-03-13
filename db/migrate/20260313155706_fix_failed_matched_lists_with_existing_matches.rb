class FixFailedMatchedListsWithExistingMatches < ActiveRecord::Migration[7.1]
  def up
    # Fix any aggregated lists stuck in 'failed' that actually have valid matches.
    # A matching job error shouldn't permanently block ordering when data is fine.
    execute <<~SQL
      UPDATE aggregated_lists
      SET match_status = 'matched'
      WHERE match_status = 'failed'
        AND id IN (
          SELECT DISTINCT aggregated_list_id
          FROM product_matches
        )
    SQL
  end

  def down
    # No-op — we can't know which lists were originally failed
  end
end
