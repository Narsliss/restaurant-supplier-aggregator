class BaselineLinkSnapshot < ApplicationRecord
  # Generic snapshot of a product_id we repointed (record_type is
  # "SupplierProduct" or "OrderListItem"), so a baseline run rolls back exactly.
end
