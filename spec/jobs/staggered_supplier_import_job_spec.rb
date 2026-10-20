require 'rails_helper'

RSpec.describe StaggeredSupplierImportJob do
  include ActiveJob::TestHelper

  # docs/fix-morning-sync-at-scale.md: the 8 AM guide sync stopped importing
  # Sysco's catalog per login because this 6 AM run already does, once a day.
  it 'still imports the Sysco catalog through the combined job, with one login' do
    sysco = Supplier.find_by!(code: 'sysco') # seeded at boot
    owner = create(:user, :with_organization)
    login = create(:supplier_credential, user: owner, supplier: sysco, organization_id: owner.current_organization_id)

    described_class.perform_now

    jobs = enqueued_jobs.select { |j| j['job_class'] == 'SyscoCombinedImportJob' }
    expect(jobs.map { |j| j['arguments'].first }).to eq([login.id])
  end
end
