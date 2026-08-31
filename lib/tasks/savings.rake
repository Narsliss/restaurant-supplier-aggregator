# Recompute persisted savings against the current catalog.
#
# savings_amount was written once at order time by the old comparison, which
# took a raw MAX(current_price) with no unit conversion. Those numbers cannot be
# corrected in place -- they have to be re-derived. Carmin chose to recompute at
# today's prices rather than keep a second, legacy basis alive.
#
#   rake savings:recompute            # dry run, prints the delta
#   rake savings:recompute APPLY=1    # writes
#   rake savings:recompute ORG=7      # one organization
namespace :savings do
  task recompute: :environment do
    apply = ENV["APPLY"] == "1"
    scope = Order.all
    scope = scope.where(organization_id: ENV["ORG"]) if ENV["ORG"].present?

    before = scope.sum(:savings_amount).to_f
    realized = 0.0
    missed = 0.0
    changed = 0

    puts "Recomputing #{scope.count} orders — #{apply ? 'WRITE' : 'DRY RUN'}"

    scope.includes(order_items: :supplier_product).find_each do |order|
      breakdown = order.savings_breakdown
      realized += breakdown[:realized]
      missed += breakdown[:missed]
      changed += 1 if (breakdown[:realized] - order.savings_amount.to_f).abs > 0.005
      next unless apply

      order.update_columns(
        savings_amount: breakdown[:realized],
        missed_savings_amount: breakdown[:missed]
      )
    end

    puts format("  stored before:      $%.2f", before)
    puts format("  realized after:     $%.2f", realized)
    puts format("  missed after:       $%.2f", missed)
    puts format("  orders that move:   %d", changed)
    puts(apply ? "  WRITTEN" : "  DRY RUN — pass APPLY=1 to write")
  end
end
