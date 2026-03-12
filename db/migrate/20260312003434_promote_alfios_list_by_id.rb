class PromoteAlfiosListById < ActiveRecord::Migration[7.1]
  def up
    list = AggregatedList.find_by(id: 8)
    unless list
      say "AggregatedList #8 not found — skipping"
      return
    end

    say "Found list '#{list.name}' (id: #{list.id})"

    # Set as master list type
    list.update_columns(list_type: "master")
    say "Set list_type to 'master'"

    # Assign to first location in the org if not already set
    if list.location_id.nil? && list.organization_id.present?
      location = Location.where(organization_id: list.organization_id).first
      if location
        list.update_columns(location_id: location.id)
        say "Assigned to location '#{location.name}'"
      end
    end

    # Promote as org-wide default
    if list.organization_id.present?
      AggregatedList.where(organization_id: list.organization_id, promoted_org_wide: true)
                    .where.not(id: list.id)
                    .update_all(promoted_org_wide: false)
    end
    list.update_columns(promoted_org_wide: true)
    say "Promoted as org-wide default"
  end

  def down
    list = AggregatedList.find_by(id: 8)
    return unless list

    list.update_columns(list_type: "custom", promoted_org_wide: false)
  end
end
