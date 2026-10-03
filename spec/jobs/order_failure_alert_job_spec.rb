require 'rails_helper'

# Carmin's rule (Oct 3 2026, order #386): a not-placed order the chef sees in
# the app gets no email; one she didn't see emails her and the owner(s).
# Unconfirmed and stuck orders always email.
RSpec.describe OrderFailureAlertJob, type: :job do
  let(:owner) { create(:user, :with_organization) }
  let(:org) { owner.current_organization }
  let(:chef) { create(:user).tap { |u| create(:membership, user: u, organization: org, role: 'chef') } }
  let(:supplier) { create(:supplier, name: "Chef's Warehouse") }
  let(:order) do
    create(:order, user: chef, supplier: supplier, organization: org, status: 'failed',
                   delivery_date: Date.new(2026, 10, 2),
                   error_message: "Not placed. Chef's Warehouse couldn't take 1 item: Honey — removed at checkout.")
  end

  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  before { ActionMailer::Base.deliveries.clear }

  def schedule_and_run(kind: 'not_placed')
    described_class.schedule(order, kind: kind)
    job = enqueued_jobs.reverse.find { |j| j['job_class'] == 'OrderFailureAlertJob' }
    described_class.perform_now(*ActiveJob::Arguments.deserialize(job['arguments']))
  end

  describe '.schedule' do
    it 'waits 2 minutes for a fixable failure, so the chef can see it in the app first' do
      freeze_time do
        expect { described_class.schedule(order) }
          .to have_enqueued_job(described_class).at(2.minutes.from_now)
      end
    end

    it 'sends an unconfirmed alert right away' do
      freeze_time do
        expect { described_class.schedule(order, kind: 'unconfirmed') }
          .to have_enqueued_job(described_class).at(Time.current)
      end
    end

    it 'never raises into the placement path' do
      allow(described_class).to receive(:set).and_raise(StandardError, 'queue down')

      expect { described_class.schedule(order) }.not_to raise_error
    end
  end

  describe '#perform' do
    it 'emails the chef and the owner when the chef never saw the failure' do
      schedule_and_run

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to contain_exactly(chef.email, owner.email)
      expect(mail.subject).to eq("[EnPlace Pro] NOT PLACED: your Chef's Warehouse order for Fri Oct 2")
      expect(mail.html_part ? mail.html_part.body.to_s : mail.body.to_s).to include('This order was NOT placed', 'Honey')
    end

    it 'sends nothing when the chef saw the failure in the app' do
      described_class.schedule(order)
      travel 30.seconds
      described_class.mark_seen(order)
      job = enqueued_jobs.last
      described_class.perform_now(*ActiveJob::Arguments.deserialize(job['arguments']))

      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'still emails when the only "seen" was before this failure' do
      described_class.mark_seen(order)
      travel 1.minute

      schedule_and_run

      expect(ActionMailer::Base.deliveries.size).to eq(1)
    end

    it 'sends nothing when the order was placed or resubmitted since' do
      described_class.schedule(order)
      order.update!(status: 'submitted')
      described_class.perform_now(*ActiveJob::Arguments.deserialize(enqueued_jobs.last['arguments']))

      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'leaves a superseded failure to the newer attempt' do
      described_class.schedule(order)
      first = enqueued_jobs.last
      travel 1.second
      described_class.schedule(order)

      described_class.perform_now(*ActiveJob::Arguments.deserialize(first['arguments']))

      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'emails once even if the job runs twice' do
      described_class.schedule(order)
      args = ActiveJob::Arguments.deserialize(enqueued_jobs.last['arguments'])
      2.times { described_class.perform_now(*args) }

      expect(ActionMailer::Base.deliveries.size).to eq(1)
    end

    it 'emails an unconfirmed order even when the chef is looking at it' do
      order.update!(status: 'pending_manual', error_message: 'Check the Premiere Produce app before reordering')
      described_class.mark_seen(order)
      travel 1.second

      schedule_and_run(kind: 'unconfirmed')

      expect(ActionMailer::Base.deliveries.last.subject).to include('may not have gone through')
    end

    it 'fails safe to emailing when the cache keeps nothing' do
      Rails.cache = ActiveSupport::Cache::NullStore.new
      described_class.schedule(order)
      described_class.mark_seen(order)

      described_class.perform_now(*ActiveJob::Arguments.deserialize(enqueued_jobs.last['arguments']))

      expect(ActionMailer::Base.deliveries.size).to eq(1)
    end

    it 'sends one email when the chef is also the owner' do
      order.update!(user: owner)

      schedule_and_run

      expect(ActionMailer::Base.deliveries.last.to).to eq([owner.email])
    end
  end

  describe StuckOrderAlertJob do
    it 'emails once about an order processing for over 15 minutes' do
      order.update!(status: 'processing')
      order.update_column(:updated_at, 20.minutes.ago)

      2.times { described_class.perform_now }

      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(ActionMailer::Base.deliveries.last.subject).to include("hasn't gone through yet")
    end

    it 'leaves a recently started order alone' do
      order.update!(status: 'processing')

      described_class.perform_now

      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end
end
