require 'rails_helper'

# Oct 20 2026: 35 of Alfio's lists sat "syncing" for days (D'oro's Chef's
# Warehouse lists since Oct 17, alfios' and Noche's US Foods lists since
# Oct 18). A guide sync marked, skipped and failed lists across the whole
# organization, but only ever cleared the ones its own login reached
# (docs/fix-stuck-syncing-lists.md).
RSpec.describe ImportSupplierListsJob, 'which lists a sync touches' do
  include ActiveJob::TestHelper

  let(:owner) { create(:user, :with_organization) }
  let(:org) { owner.current_organization }
  let(:supplier) { create(:supplier) }
  let(:alfios) { create(:location, organization: org, user: owner, name: 'alfios') }
  let(:noche) { create(:location, organization: org, user: owner, name: 'Noche') }
  let(:doro) { create(:location, organization: org, user: owner, name: "D'oro") }
  let(:login) do
    create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id, location_id: alfios.id)
  end
  let(:result) { { lists_synced: 1, items_imported: 0, items_updated: 0, errors: [] } }

  def list_at(location, status: 'synced', synced_at: 1.day.ago)
    create(:supplier_list, supplier: supplier, organization: org, location: location,
                           sync_status: status, last_synced_at: synced_at)
  end

  before { allow(ImportSupplierListsService).to receive(:new).and_return(double(call: result)) }

  it "leaves other restaurants' lists alone when one restaurant syncs" do
    own = list_at(alfios)
    other = list_at(doro)

    described_class.perform_now(login.id)

    expect(own.reload.sync_status).to eq('syncing') # the stubbed service never finishes it
    expect(other.reload.sync_status).to eq('synced') # was left "syncing" for good
  end

  it "does not skip a restaurant because another restaurant's lists are fresh" do
    list_at(alfios, synced_at: 10.hours.ago)
    list_at(doro, synced_at: 1.hour.ago)

    described_class.perform_now(login.id)

    expect(ImportSupplierListsService).to have_received(:new) # was skipped, with no log
  end

  it "still skips when the login's own lists are fresh" do
    list_at(alfios, synced_at: 1.hour.ago)

    described_class.perform_now(login.id)

    expect(ImportSupplierListsService).not_to have_received(:new)
  end

  it "marks each restaurant on a multi-restaurant login, and only those" do
    SupplierCredentialRestaurant.create!(supplier_credential: login, location: alfios, supplier_account_id: 'A1')
    SupplierCredentialRestaurant.create!(supplier_credential: login, location: noche, supplier_account_id: 'N1')
    on_login = [list_at(alfios), list_at(noche)]
    other = list_at(doro)

    described_class.perform_now(login.id)

    expect(on_login.map { |l| l.reload.sync_status }).to all(eq('syncing'))
    expect(other.reload.sync_status).to eq('synced')
  end

  it "fails only this login's lists when the sync crashes" do
    allow(ImportSupplierListsService).to receive(:new).and_return(double.tap { |d| allow(d).to receive(:call).and_raise('boom') })
    own = list_at(alfios)
    other = list_at(doro, status: 'syncing')

    expect { described_class.perform_now(login.id) }.to raise_error(RuntimeError, 'boom')

    expect(own.reload.sync_status).to eq('failed')
    expect(other.reload.sync_status).to eq('syncing')
  end
end

RSpec.describe ImportSupplierListsService, "judging lists 'no longer found'" do
  let(:owner) { create(:user, :with_organization) }
  let(:org) { owner.current_organization }
  let(:supplier) { create(:supplier) }
  let(:noche) { create(:location, organization: org, user: owner, name: 'Noche') }
  let(:alfios) { create(:location, organization: org, user: owner, name: 'alfios') }
  let(:chef_login) do
    create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id, location_id: noche.id)
  end

  it "only judges the login's own restaurant's lists" do
    gone_here = create(:supplier_list, supplier: supplier, organization: org, location: noche, remote_list_id: 'OLD')
    elsewhere = create(:supplier_list, supplier: supplier, organization: org, location: alfios, remote_list_id: 'SL-9')

    described_class.new(chef_login).send(:mark_removed_lists, ['SL-1'])

    expect(gone_here.reload).to have_attributes(sync_status: 'failed', sync_error: 'List no longer found on supplier site')
    expect(elsewhere.reload.sync_status).to eq('synced') # a Noche chef's Sync used to fail alfios' lists
  end
end
