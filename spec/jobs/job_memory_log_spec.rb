require 'rails_helper'

# Finding which jobs make the worker's memory climb (docs/job-memory-log.md).
RSpec.describe JobMemoryLog do
  let(:job_class) do
    Class.new(ApplicationJob) do
      queue_as :low
      def self.name = 'MemoryProbeJob'
      def perform(fail: false)
        raise 'boom' if fail
      end
    end
  end
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def run_with_rss(before, after, **args)
    allow(described_class).to receive(:rss_mb).and_return(before, after)
    job_class.perform_now(**args)
  end

  def todays_rows = cache.read("job_memory:#{Date.current.iso8601}") || []

  it 'logs and keeps a row when a job grows its process by 25 MB or more' do
    expect(Rails.logger).to receive(:info).with(/\[JobMemory\] MemoryProbeJob \(low\) grew its process 200->580 MB \(\+380\)/)
    allow(Rails.logger).to receive(:info)

    run_with_rss(200.0, 580.0)

    expect(todays_rows.size).to eq(1)
    expect(todays_rows.first).to include('job' => 'MemoryProbeJob', 'queue' => 'low', 'before_mb' => 200,
                                         'after_mb' => 580, 'alongside' => 0)
  end

  it 'stays quiet for small growth' do
    run_with_rss(200.0, 210.0)

    expect(todays_rows).to be_empty
  end

  it 'still records a job that raises' do
    expect { run_with_rss(200.0, 300.0, fail: true) }.to raise_error(RuntimeError, 'boom')

    expect(todays_rows.map { |r| r['job'] }).to eq(['MemoryProbeJob'])
  end

  it 'reads resident memory from /proc/self/status on Linux' do
    allow(File).to receive(:foreach).with('/proc/self/status')
                                    .and_yield("Name:\truby\n").and_yield("VmRSS:\t  524288 kB\n")

    expect(described_class.rss_mb).to eq(512.0)
  end

  it 'does nothing where memory cannot be read (no /proc, as on macOS)' do
    run_with_rss(nil, nil)

    expect(todays_rows).to be_empty
  end

  it 'never fails a job because recording failed' do
    allow(cache).to receive(:write).and_raise(StandardError, 'cache down')

    expect { run_with_rss(200.0, 300.0) }.not_to raise_error
  end

  it 'keeps at most KEPT_PER_DAY rows for a day' do
    cache.write("job_memory:#{Date.current.iso8601}", Array.new(described_class::KEPT_PER_DAY) { { 'job' => 'Old' } })

    run_with_rss(200.0, 300.0)

    expect(todays_rows.size).to eq(described_class::KEPT_PER_DAY)
    expect(todays_rows.last['job']).to eq('MemoryProbeJob')
  end
end
