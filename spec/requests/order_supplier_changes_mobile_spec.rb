require 'rails_helper'

# Supplier changes to a placed order (US Foods shorts, Premiere Produce
# splits onto later days) showed only on the desktop order page. Chefs order
# on phones (Oct 2026).
RSpec.describe 'Supplier changes on the mobile order page', type: :request do
  MOBILE_UA_CHANGES = { 'HTTP_USER_AGENT' => 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)' }.freeze

  let(:user) { create(:user, :fully_onboarded) }
  let(:org) { user.current_organization }
  let(:supplier) { create(:supplier, name: 'Premiere Produce One') }
  let!(:order) do
    create(:order, user: user, supplier: supplier, organization: org, location: org.locations.first,
                   status: 'submitted', delivery_date: Date.new(2026, 10, 20), confirmation_number: 'ppo-1',
                   supplier_exceptions: [{ 'sku' => '01298', 'name' => 'Bone Marrow', 'type' => 'delivery_changed',
                                           'ordered' => 1, 'filled' => 1,
                                           'message' => 'Arrives Wed Oct 28 — Premiere Produce put it on a separate order' }])
  end

  before { sign_in user }

  it 'shows which item arrives on a later day' do
    get order_path(order), headers: MOBILE_UA_CHANGES

    expect(response.body).to include('Arrives later', 'Bone Marrow', 'Arrives Wed Oct 28')
  end
end
