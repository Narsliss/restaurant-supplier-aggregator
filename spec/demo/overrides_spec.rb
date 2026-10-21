# frozen_string_literal: true

require_relative 'demo_spec_helper'

RSpec.describe DemoMode::Overrides do
  let(:user) { create(:user, :with_organization) }
  let(:supplier) { create(:supplier, :two_fa) }
  let(:cred) do
    create(:supplier_credential, user: user, supplier: supplier, status: 'active',
                                 session_data: nil, last_login_at: 3.days.ago)
  end

  describe 'whether a login is connected' do
    context 'with demo mode off' do
      it 'is exactly as before: no fresh session, not connected' do
        expect(cred.session_valid?).to be(false)

        cred.update!(session_data: '{"cookies":[]}', last_login_at: 1.hour.ago)
        expect(cred.session_valid?).to be(true)
      end
    end

    context 'with demo mode on' do
      include_context 'demo mode on'

      it 'counts any active login as connected' do
        expect(cred.session_valid?).to be(true)
      end

      it 'does not count a failed login' do
        cred.update!(status: 'failed')
        expect(cred.session_valid?).to be(false)
      end
    end
  end

  describe "listing a login's restaurants" do
    let(:org) { user.current_organization }

    before do
      create(:location, organization: org, user: user, name: 'Downtown')
      create(:location, organization: org, user: user, name: 'Harbor')
    end

    context 'with demo mode on' do
      include_context 'demo mode on'

      it "lists the organization's restaurants without asking the supplier" do
        expect(Suppliers::RestaurantSwitcher).not_to receive(:list_restaurants)

        list = Suppliers::RestaurantMatching.new(cred).restaurants

        expect(list.map { |r| r[:name] }).to include('Downtown', 'Harbor')
        expect(list.map { |r| r[:id] }).to all(start_with('DEMO-'))
      end

      it "prefers the login's remembered list" do
        cred.update!(supplier_restaurants: [{ 'id' => '42', 'name' => 'Bella Vista Downtown', 'meta' => {} }])

        expect(Suppliers::RestaurantMatching.new(cred).restaurants)
          .to eq([{ id: '42', name: 'Bella Vista Downtown', meta: {} }])
      end
    end

    context 'with demo mode off' do
      it 'asks the supplier, as before' do
        allow(cred.supplier).to receive(:scraper_klass).and_return(double(new: double(api_client: :api)))
        expect(Suppliers::RestaurantSwitcher).to receive(:list_restaurants).with(cred, :api).and_return([])

        Suppliers::RestaurantMatching.new(cred).restaurants
      end
    end
  end
end
