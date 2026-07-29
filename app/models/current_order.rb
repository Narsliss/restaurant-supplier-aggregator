# The chef's one persistent working order (the mobile Order tab):
# every add/remove in the builder saves here immediately, and returning to
# the builder repopulates from it. Create Cart re-seeds the batch from this
# state WITHOUT clearing it (chefs go back for forgotten items); only placing
# the order — or the explicit "Clear order" button — empties it.
class CurrentOrder < ApplicationRecord
  belongs_to :user
  belongs_to :aggregated_list

  # Raw state comes straight from the builder JS:
  #   { "match_id" => { "supplierId" => "12", "qty" => 3, "uom" => "CS" } }
  # Sanitize on read — drop zero/negative quantities and malformed entries.
  def sanitized_state
    return {} unless state.is_a?(Hash)

    state.each_with_object({}) do |(match_id, entry), out|
      next unless entry.is_a?(Hash)
      qty = entry["qty"].to_f
      next if qty <= 0

      out[match_id.to_s] = {
        "supplierId" => entry["supplierId"].to_s,
        "qty" => qty,
        "uom" => entry["uom"].presence || "CS"
      }
    end
  end

  def empty?
    sanitized_state.empty?
  end
end
