require 'rails_helper'

# Where the "your list is ready" email hangs off the matching pipeline.
# Matching can chain into a catalog search; whichever step actually ends the
# chain is the one that gets to speak, so the email never quotes counts that
# are still moving.
RSpec.describe 'match completion email wiring' do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:location) { org.locations.first }
  let(:list) do
    AggregatedList.find_by!(organization: org, location_id: location.id, list_type: 'matched')
  end

  describe AiProductMatchJob do
    before { allow_any_instance_of(AiProductMatcherService).to receive(:call) }

    it 'notifies when there is nothing left to chain' do
      list.update!(match_status: 'matched')
      allow_any_instance_of(AggregatedList).to receive(:unmatched_count).and_return(0)

      expect(MatchCompletionNotifier).to receive(:call)

      described_class.perform_now(list.id)
    end

    it 'stays quiet and hands off when a catalog search still has to run' do
      list.update!(match_status: 'matched')
      allow_any_instance_of(AggregatedList).to receive(:unmatched_count).and_return(4)

      expect(MatchCompletionNotifier).not_to receive(:call)
      expect(CatalogSearchJob).to receive(:perform_later).with(list.id)

      described_class.perform_now(list.id)
    end
  end

  describe CatalogSearchJob do
    before { allow_any_instance_of(CatalogSearchService).to receive(:call) }

    it 'notifies at the end of the sign-up chain' do
      expect(MatchCompletionNotifier).to receive(:call)

      described_class.perform_now(list.id)
    end

    it 'stays quiet when a chef re-searches specific rows' do
      expect(MatchCompletionNotifier).not_to receive(:call)

      described_class.perform_now(list.id, match_ids: [1, 2])
    end

    it 'still marks the search done when the service blows up' do
      allow_any_instance_of(CatalogSearchService).to receive(:call).and_raise(StandardError, 'boom')

      expect { described_class.perform_now(list.id) }.to raise_error(StandardError, 'boom')
      expect(list.reload).not_to be_searching_catalog
    end
  end
end
