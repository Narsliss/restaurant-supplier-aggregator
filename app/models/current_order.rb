# The chef's one persistent working order (the mobile Order tab):
# every add/remove in the builder saves here immediately, and returning to
# the builder repopulates from it. Create Cart re-seeds the batch from this
# state WITHOUT clearing it (chefs go back for forgotten items); only placing
# the order — or the explicit "Clear order" button — empties it.
class CurrentOrder < ApplicationRecord
  belongs_to :user
  belongs_to :aggregated_list

  # Raw state comes straight from the builder JS. A product can be sourced
  # from more than one supplier at once — 5 salads from PPO plus 1 from WCW
  # to clear WCW's order minimum — so each match holds a LIST of lines:
  #   { "match_id" => [{ "supplierId" => "12", "qty" => 5, "uom" => "CS" }, ...] }
  #
  # Working orders saved before splitting existed hold a single bare hash per
  # match. Read those as a one-line list so a chef mid-order doesn't lose
  # their cart when this ships.
  #
  # Sanitize on read — drop zero/negative quantities and malformed entries.
  def sanitized_state
    return {} unless state.is_a?(Hash)

    state.each_with_object({}) do |(match_id, entry), out|
      lines = Array.wrap(entry).filter_map do |line|
        next unless line.is_a?(Hash)
        qty = line["qty"].to_f
        next if qty <= 0

        {
          "supplierId" => line["supplierId"].to_s,
          "qty" => qty,
          "uom" => line["uom"].presence || "CS"
        }
      end
      # One supplier can only appear once per product — merge if the client
      # ever sends duplicates rather than silently ordering twice.
      lines = lines.group_by { |l| l["supplierId"] }.map do |supplier_id, group|
        { "supplierId" => supplier_id, "qty" => group.sum { |l| l["qty"] }, "uom" => group.first["uom"] }
      end
      out[match_id.to_s] = lines if lines.any?
    end
  end

  def empty?
    sanitized_state.empty?
  end
end
