# Tombstone marking that a location was ONCE auto-seeded with a
# "Recent <Supplier> Orders" order list. Survives the list's deletion, so
# the automatic seeder (daily sync path) never resurrects a list the chef
# deleted — only the explicit "Refresh Recent Orders" button re-creates it.
class OrderListSeedRecord < ApplicationRecord
  belongs_to :location
  belongs_to :supplier

  validates :supplier_id, uniqueness: { scope: :location_id }
end
