class PromoteAlfiosMatchedList < ActiveRecord::Migration[7.1]
  def up
    user = User.find_by(email: "alfio@alfios-cincy.com")
    unless user
      say "User alfio@alfios-cincy.com not found — skipping"
      return
    end

    org = user.organizations.first
    unless org
      say "No organization found for #{user.email} — skipping"
      return
    end

    list = AggregatedList.where(organization: org, list_type: %w[matched master]).first
    unless list
      say "No matched list found in org #{org.name} — skipping"
      return
    end

    say "Found list '#{list.name}' (id: #{list.id}) in org #{org.name}"

    # Assign to location if not already set
    location = org.locations.first
    if location && list.location_id.nil?
      list.update_columns(location_id: location.id)
      say "Assigned to location '#{location.name}'"
    end

    # Demote any other promoted list
    AggregatedList.where(organization: org, promoted_org_wide: true)
                  .where.not(id: list.id)
                  .update_all(promoted_org_wide: false)

    # Promote
    list.update_columns(promoted_org_wide: true)
    say "Promoted '#{list.name}' as org-wide default for #{org.name}"
  end

  def down
    user = User.find_by(email: "alfio@alfios-cincy.com")
    return unless user

    org = user.organizations.first
    return unless org

    list = AggregatedList.where(organization: org, list_type: %w[matched master]).first
    list&.update_columns(promoted_org_wide: false)
  end
end
