# frozen_string_literal: true

require_relative 'demo_spec_helper'

# The screens the sales team clicks through, with the switch off (as in
# production) and on (as on the demo).
RSpec.describe 'Demo screens', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:location) { org.locations.first }
  let(:two_fa_supplier) { create(:supplier, :two_fa, name: 'Code Login Foods') }
  let!(:cred) do
    create(:supplier_credential, user: owner, supplier: two_fa_supplier, location: location, status: 'active',
                                 session_data: nil, last_login_at: 3.days.ago)
  end

  before { sign_in owner }

  describe 'Supplier Credentials' do
    it 'shows a stale code-login as disconnected with the switch off (production unchanged)' do
      get supplier_credentials_path

      expect(response.body).to include('Disconnected', 'Session expired')
    end

    context 'with demo mode on' do
      include_context 'demo mode on'

      it 'shows every active login as connected' do
        get supplier_credentials_path

        expect(response.body).to include('Connected')
        expect(response.body).not_to include('Disconnected', 'Session expired')
      end

      context 'with jobs as on the demo' do
        include_context 'demo jobs inline'

        it 'Validate reconnects without contacting the supplier' do
          expect(Authentication::SessionManager).not_to receive(:new)

          post validate_supplier_credential_path(cred)

          expect(cred.reload.status).to eq('active')
          expect(cred.importing).to be(false)
        end
      end
    end
  end

  describe 'submitting an order' do
    let(:supplier) { create(:supplier, :checkout_enabled) }
    let(:order) { create(:order, user: owner, supplier: supplier, organization: org, location_id: location.id) }

    before { create(:order_item, order: order) }

    context 'with demo mode on and jobs as on the demo' do
      include_context 'demo mode on'
      include_context 'demo jobs inline'

      it 'ends at a demo confirmation, never at the supplier' do
        expect(Orders::OrderPlacementService).not_to receive(:new)

        post submit_order_path(order)
        follow_redirect!

        expect(order.reload.status).to eq('submitted')
        expect(response.body).to include(order.confirmation_number)
      end
    end
  end
end
