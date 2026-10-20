require 'rails_helper'

RSpec.describe 'config/queue.yml' do
  let(:workers) { YAML.load_file(Rails.root.join('config/queue.yml'), aliases: true).dig('production', 'workers') }

  # Order placement (PlaceOrderJob) never shares a process with anything else.
  it 'keeps the critical queue alone in its own process' do
    critical = workers.select { |w| w['queues'].include?('critical') }
    expect(critical.size).to eq(1)
    expect(critical.first['queues']).to eq(['critical'])
  end

  # docs/fix-morning-sync-at-scale.md: guide syncs don't wait behind imports.
  it 'gives guide syncs their own process, apart from the catalog imports' do
    list_sync = workers.find { |w| w['queues'] == ['list_sync'] }
    expect(list_sync).to be_present
    expect(list_sync['threads']).to be_between(2, 9) # production DB pool is 10 per process
    expect(workers.find { |w| w['queues'].include?('scraping') }['queues']).not_to include('list_sync')
  end
end
