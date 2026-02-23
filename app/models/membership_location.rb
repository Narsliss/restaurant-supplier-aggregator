class MembershipLocation < ApplicationRecord
  belongs_to :membership
  belongs_to :location

  validates :location_id, uniqueness: { scope: :membership_id, message: "is already assigned to this member" }
end
