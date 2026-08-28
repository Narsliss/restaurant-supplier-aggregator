class AddComparisonBasisToOrderItems < ActiveRecord::Migration[7.1]
  def change
    # What the routing decision rested on when this line was placed: the
    # suppliers' own shared unit, an estimated pack weight, a single supplier,
    # or nothing but case totals. Recorded at placement because it cannot be
    # recovered afterwards — the comparison recomputes from today's data, and
    # a weight set next month would silently rewrite what we thought last
    # month. Reports stay live for now; this is the cheap hedge that keeps
    # pinning them a read-side change later rather than an impossible one.
    add_column :order_items, :comparison_basis, :string
    add_index :order_items, :comparison_basis
  end
end
