# A record of an item leaving a matched row — what it was, which row it left,
# and what removed it. Written by ProductMatchItem on every destroy (except a
# whole organization being deleted). The cause comes from MatchChange.
class MatchItemRemoval < ApplicationRecord
  CAUSES = %w[chef_edit cleanup_merge auto_merge rematch_all row_deleted
              supplier_connection_removed supplier_deleted unspecified].freeze

  validates :cause, inclusion: { in: CAUSES }
end
