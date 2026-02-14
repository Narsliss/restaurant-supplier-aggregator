# frozen_string_literal: true

class QuickPriceUpdateJob < ApplicationJob
  queue_as :scraping

  # Run every 15 minutes for active organizations
  # Target duration: < 10 minutes total
  def perform(organization_id = nil)
    if organization_id
      # Update specific organization
      organization = Organization.find_by(id: organization_id)
      return unless organization

      QuickPriceUpdateService.new(organization).update_all_suppliers
    else
      # Update all active organizations
      Organization.active.find_each do |org|
        # Queue individual jobs for each organization to parallelize
        QuickPriceUpdateJob.perform_later(org.id)
      end
    end
  end
end
