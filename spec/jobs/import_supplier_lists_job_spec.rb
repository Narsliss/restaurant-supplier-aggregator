require 'rails_helper'

# docs/fix-morning-sync-at-scale.md: at 8 AM a Sysco login syncs its guide
# here, then refreshes its delivery dates using the session the sync checked.
RSpec.describe ImportSupplierListsJob do
  include ActiveJob::TestHelper

  let(:owner) { create(:user, :with_organization) }
  let(:supplier) { Supplier.find_by!(code: 'sysco') } # seeded at boot
  let(:restaurant) { create(:location, organization: owner.current_organization, user: owner) }
  let(:credential) do
    create(:supplier_credential, user: owner, supplier: supplier, organization_id: owner.current_organization_id,
                                 location_id: restaurant.id)
  end
  let(:result) { { lists_synced: 1, items_imported: 2, items_updated: 0, errors: [] } }

  before do
    allow(ImportSupplierListsService).to receive(:new).and_return(double(call: result))
  end

  def dates_jobs
    enqueued_jobs.select { |j| j['job_class'] == 'FetchSyscoDeliveryDatesJob' }
  end

  it 'queues the delivery dates after the guide sync when asked' do
    described_class.perform_now(credential.id, delivery_dates: true)

    expect(dates_jobs.size).to eq(1)
    expect(dates_jobs.first['arguments'].first).to eq(credential.id)
    expect(dates_jobs.first['arguments'].last).to include('force' => true)
  end

  it 'still refreshes the delivery dates when the guide was synced recently and is skipped' do
    create(:supplier_list, supplier: supplier, organization: owner.current_organization, location: restaurant,
                           sync_status: 'synced', last_synced_at: 1.hour.ago)

    described_class.perform_now(credential.id, delivery_dates: true)

    expect(ImportSupplierListsService).not_to have_received(:new)
    expect(dates_jobs.size).to eq(1)
  end

  it 'leaves delivery dates alone by default (a chef pressing Sync)' do
    described_class.perform_now(credential.id)

    expect(dates_jobs).to be_empty
  end

  it 'keeps the errors the sync caught on its log, for the 9:15 report' do
    result[:errors] << 'HTTP 429 for GetLists'

    described_class.perform_now(credential.id)

    log = ScrapingLog.where(supplier_credential: credential).last
    expect(log.status).to eq('completed')
    expect(log.metadata['errors']).to eq(['HTTP 429 for GetLists'])
  end
end
