class PromoteAlfiosMatchedList < ActiveRecord::Migration[7.1]
  # No-op: the list is safe and the user will promote it manually via the UI.
  # Previous version failed because it referenced a column not yet in production.
  def up
    say "No-op — Alfios list promotion will be done via UI"
  end

  def down
    # nothing to undo
  end
end
