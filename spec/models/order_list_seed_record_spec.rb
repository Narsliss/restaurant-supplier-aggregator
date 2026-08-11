require 'rails_helper'

RSpec.describe OrderListSeedRecord, type: :model do
  it 'allows only one record per location+supplier' do
    user = create(:user, :with_organization)
    location = create(:location, organization: user.current_organization, user: user)
    supplier = create(:supplier)

    described_class.create!(location: location, supplier: supplier, seeded_at: Time.current)
    dup = described_class.new(location: location, supplier: supplier)

    expect(dup).not_to be_valid
  end
end
