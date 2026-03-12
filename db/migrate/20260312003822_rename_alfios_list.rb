class RenameAlfiosList < ActiveRecord::Migration[7.1]
  def up
    list = AggregatedList.find_by(id: 8)
    unless list
      say "AggregatedList #8 not found — skipping"
      return
    end

    old_name = list.name
    list.update_columns(name: "Alfios Matched List")
    say "Renamed '#{old_name}' → 'Alfios Matched List'"
  end

  def down
    list = AggregatedList.find_by(id: 8)
    list&.update_columns(name: "commodities2")
  end
end
