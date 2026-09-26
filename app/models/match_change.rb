# Labels WHY items are leaving matched rows during a request or job, so each
# MatchItemRemoval says what did it ("chef_edit", "supplier_connection_removed",
# ...). Purely descriptive: protection comes from the database, which refuses
# to delete a supplier list item any matched row still uses.
#
#   MatchChange.as("chef_edit") { ... }
class MatchChange < ActiveSupport::CurrentAttributes
  attribute :cause, :user

  def self.as(cause, &block)
    set(cause: cause, &block)
  end
end
