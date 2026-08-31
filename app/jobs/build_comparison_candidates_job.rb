# Rebuilds the automatic cross-supplier alternatives for an organization basket.
#
# Runs per organization because a basket is small and stable — a couple of
# hundred products that barely change month to month — while the catalog it is
# matched against is ~58,000 rows. Nightly is ample; nothing here is required
# for an order to be placed.
class BuildComparisonCandidatesJob < ApplicationJob
  queue_as :low

  def perform(organization_id = nil)
    scope = organization_id ? Organization.where(id: organization_id) : Organization.all

    scope.find_each do |organization|
      result = Catalog::BasketCandidateMatcher.new(organization).call
      Rails.logger.info(
        "[ComparisonCandidates] org=#{organization.id} examined=#{result.products_examined} " \
        "matched=#{result.products_matched} written=#{result.candidates_written}"
      )
    end
  end
end
