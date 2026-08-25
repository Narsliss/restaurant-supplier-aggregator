require 'rails_helper'

RSpec.describe MatchCompletionNotifier do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:location) { org.locations.first }
  let(:list) do
    AggregatedList.find_by!(organization: org, location_id: location.id, list_type: 'matched')
  end

  def with_a_match(target = list)
    create(:product_match, aggregated_list: target, match_status: 'auto_matched')
  end

  def ready!(target = list)
    target.update!(match_status: 'matched', catalog_search_status: 'done')
    with_a_match(target)
    target
  end

  describe 'the first list a new customer finishes' do
    it 'emails the owner' do
      ready!

      expect { described_class.call(list) }
        .to change { ActionMailer::Base.deliveries.size + enqueued_mail_count }.by(1)
    end

    it 'stamps the list so it can never send twice' do
      ready!

      expect { described_class.call(list) }.to change { list.reload.completion_emailed_at }.from(nil)
    end

    it 'stays quiet on a second call' do
      ready!
      described_class.call(list)

      expect { described_class.call(list.reload) }.not_to change { enqueued_mail_count }
    end
  end

  describe 'when it must stay quiet' do
    it 'says nothing while matching is still running' do
      list.update!(match_status: 'matching')
      with_a_match

      expect { described_class.call(list) }.not_to change { enqueued_mail_count }
      expect(list.reload.completion_emailed_at).to be_nil
    end

    it 'says nothing while the catalog search is still filling gaps' do
      list.update!(match_status: 'matched', catalog_search_status: 'searching')
      with_a_match

      expect { described_class.call(list) }.not_to change { enqueued_mail_count }
    end

    it 'says nothing about an empty list' do
      list.update!(match_status: 'matched', catalog_search_status: 'done')

      expect { described_class.call(list) }.not_to change { enqueued_mail_count }
    end

    it 'ignores rejected matches when deciding the list is empty' do
      list.update!(match_status: 'matched', catalog_search_status: 'done')
      create(:product_match, aggregated_list: list, match_status: 'rejected')

      expect { described_class.call(list) }.not_to change { enqueued_mail_count }
    end

    # This is the "new sign ups" part: it's an onboarding moment, not a status
    # feed. Once an organization has had one list land, later ones are silent.
    it 'says nothing for a second list once the organization has been told' do
      ready!
      described_class.call(list)

      second = create(:aggregated_list, organization: org, created_by: owner,
                                        location_id: location.id, match_status: 'matched')
      second.update!(catalog_search_status: 'done')
      with_a_match(second)

      expect { described_class.call(second) }.not_to change { enqueued_mail_count }
      expect(second.reload.completion_emailed_at).to be_nil
    end
  end

  describe 'safety' do
    it 'never lets a mail failure break the matching pipeline' do
      ready!
      allow(MatchingMailer).to receive(:list_ready).and_raise(StandardError, 'SMTP down')

      expect { described_class.call(list) }.not_to raise_error
    end

    it 'only one of two concurrent callers wins the send' do
      ready!

      # Both see an unstamped list; the conditional UPDATE decides.
      first = described_class.new(list)
      second = described_class.new(AggregatedList.find(list.id))

      expect(first.call).to be(true)
      expect(second.call).to be_falsey
    end
  end

  def enqueued_mail_count
    ActiveJob::Base.queue_adapter.enqueued_jobs.count { |j| j[:job] == ActionMailer::MailDeliveryJob }
  end
end
