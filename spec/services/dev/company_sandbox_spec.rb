require 'rails_helper'

RSpec.describe Dev::CompanySandbox do
  describe '.spawn (bare, live-flow default)' do
    it 'creates a company with only the paperwork gates satisfied — no lists, no credentials' do
      summary = described_class.spawn(name: 'Live Kitchen')

      org = Organization.find(summary[:org_id])
      owner = User.find_by(email: summary[:login])

      # Paperwork bypassed: subscription active, team-invite gate satisfied
      expect(owner.subscribed?).to be(true)
      expect(org.organization_invitations.pending.count).to eq(1)
      expect(org.locations.count).to eq(1)
      # Everything under test stays REAL: nothing pre-imported or pre-seeded
      expect(SupplierCredential.where(organization_id: org.id)).to be_empty
      expect(SupplierList.where(organization: org)).to be_empty
      expect(OrderList.where(organization_id: org.id)).to be_empty
      expect(summary[:mode]).to include('LIVE')
      expect(owner.valid_password?(described_class::PASSWORD)).to be(true)
    end
  end

  describe '.spawn(clone_from:) — pipeline shortcut' do
    let(:template_user) { create(:user, :with_organization) }
    let(:template_org) { template_user.current_organization }
    let(:template_location) { create(:location, organization: template_org, user: template_user) }
    let(:supplier) { create(:supplier, name: 'US Foods') }

    before do
      list = create(:supplier_list, supplier: supplier, organization: template_org,
                                    location: template_location,
                                    list_type: 'recently_purchased', remote_list_id: 'recentlyPurchased')
      sp = create(:supplier_product, supplier: supplier, supplier_sku: 'A1',
                                     product: create(:product))
      create(:supplier_list_item, supplier_list: list, sku: 'A1', name: 'Item A1',
                                  position: 0, supplier_product: sp, price: 10.0)
    end

    it 'clones lists through the real import pipeline, including seeding' do
      summary = described_class.spawn(name: 'Clone Kitchen', clone_from: template_location)

      org = Organization.find(summary[:org_id])
      expect(org.supplier_lists.count).to eq(1)
      expect(org.supplier_lists.first.supplier_list_items.pluck(:sku)).to eq(%w[A1])
      expect(summary[:seeded_order_lists]).to include('Recent US Foods Orders')
      expect(summary[:mode]).to include('CLONED')
    end
  end

  describe '.timeline' do
    it 'reports elapsed steps for the org' do
      summary = described_class.spawn(name: 'Timed Kitchen')
      org = Organization.find(summary[:org_id])

      lines = described_class.timeline(org)
      expect(lines.first).to include('company created')
    end
  end

  describe '.teardown' do
    it 'tears down completely, leaving no orphaned rows' do
      summary = described_class.spawn(name: 'Teardown Kitchen')
      org = Organization.find(summary[:org_id])
      owner_id = User.find_by(email: summary[:login]).id
      location_id = summary[:location_id]

      described_class.teardown(org)

      expect(Organization.exists?(org.id)).to be(false)
      expect(User.exists?(owner_id)).to be(false)
      expect(Subscription.where(organization_id: org.id)).to be_empty
      expect(OrganizationInvitation.where(organization_id: org.id)).to be_empty
      expect(OrderListSeedRecord.where(location_id: location_id)).to be_empty
      expect(AggregatedList.where(organization_id: org.id)).to be_empty
    end

    it 'refuses to tear down a non-sandbox organization' do
      user = create(:user, :with_organization)
      expect { described_class.teardown(user.current_organization) }.to raise_error(ArgumentError, /refusing/)
    end
  end
end
