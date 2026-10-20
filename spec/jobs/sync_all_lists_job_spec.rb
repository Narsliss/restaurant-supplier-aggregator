require 'rails_helper'

# docs/fix-morning-sync-at-scale.md. The 8 AM sync used to put every login of
# every supplier in one 30-second line, and sent each Sysco login through a
# full catalog import (~20 min) before its guide.
RSpec.describe SyncAllListsJob do
  include ActiveJob::TestHelper

  # The supplier seed creates the real suppliers at boot.
  let(:sysco) { Supplier.find_by!(code: 'sysco') }
  let(:usf) { Supplier.find_by!(code: 'usfoods') }

  def restaurant_with(*suppliers)
    owner = create(:user, :with_organization)
    org = owner.current_organization
    suppliers.map do |supplier|
      create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id)
    end
  end

  def queued(job_class)
    enqueued_jobs.select { |j| j['job_class'] == job_class.name }
  end

  # Seconds after the earliest queued sync (each sync is set(wait:) from the run).
  def waits_by_credential
    jobs = queued(ImportSupplierListsJob)
    times = jobs.to_h { |j| [j['arguments'].first, Time.zone.parse(j['scheduled_at'])] }
    start = times.values.min
    times.transform_values { |t| (t - start).round }
  end

  it 'syncs Sysco logins through the guide sync, with delivery dates, never a catalog import' do
    sysco_login = restaurant_with(sysco).first

    described_class.perform_now

    expect(queued(SyscoCombinedImportJob)).to be_empty
    job = queued(ImportSupplierListsJob).find { |j| j['arguments'].first == sysco_login.id }
    expect(job['arguments'].last).to include('delivery_dates' => true)
  end

  it 'does not ask other suppliers for delivery dates' do
    usf_login = restaurant_with(usf).first

    described_class.perform_now

    job = queued(ImportSupplierListsJob).find { |j| j['arguments'].first == usf_login.id }
    expect(job['arguments']).to eq([usf_login.id])
  end

  it 'spaces logins out per supplier, so suppliers run side by side' do
    first = restaurant_with(sysco, usf)
    second = restaurant_with(sysco, usf)

    freeze_time { described_class.perform_now }

    waits = waits_by_credential
    expect(waits.values_at(first[0].id, first[1].id)).to all(eq(0))
    expect(waits.values_at(second[0].id, second[1].id)).to all(eq(described_class::STAGGER.to_i))
  end

  it 'runs on the list_sync queue' do
    expect(described_class.new.queue_name).to eq('list_sync')
    expect(ImportSupplierListsJob.new.queue_name).to eq('list_sync')
    expect(FetchSyscoDeliveryDatesJob.new.queue_name).to eq('list_sync')
  end

  it 'is scheduled on the list_sync queue' do
    recurring = YAML.load_file(Rails.root.join('config/recurring.yml'))
    expect(recurring.dig('production', 'sync_all_lists', 'queue')).to eq('list_sync')
  end
end
