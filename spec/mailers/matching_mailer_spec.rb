require 'rails_helper'

RSpec.describe MatchingMailer, type: :mailer do
  let(:owner) { create(:user, :fully_onboarded, first_name: 'Carmin') }
  let(:org) { owner.current_organization }
  let(:location) { org.locations.first }
  let(:list) do
    AggregatedList.find_by!(organization: org, location_id: location.id, list_type: 'matched')
  end

  def match(status)
    create(:product_match, aggregated_list: list, match_status: status)
  end

  describe '#list_ready' do
    it 'goes to the owner and counts what actually matched' do
      2.times { match('auto_matched') }
      match('unmatched')
      match('rejected') # hidden from the chef, so hidden from the count

      mail = described_class.list_ready(list)

      expect(mail.to).to eq([owner.email])
      expect(mail.subject).to eq('Your price comparison is ready — 2 products matched')
      body = mail.body.encoded
      expect(body).to include('Hi Carmin')
      expect(body).to include(aggregated_list_url(list, host: 'www.example.com'))
    end

    it 'singularises a lone match' do
      match('auto_matched')

      expect(described_class.list_ready(list).subject)
        .to eq('Your price comparison is ready — 1 product matched')
    end

    it 'tells them how many still need a look' do
      match('auto_matched')
      3.times { match('unmatched') }

      body = described_class.list_ready(list).body.encoded

      expect(body).to include('Still needing a look')
      expect(body).to include("couldn't find a confident match for 3")
    end

    it 'says nothing about gaps when everything matched' do
      2.times { match('auto_matched') }

      body = described_class.list_ready(list).body.encoded

      expect(body).not_to include('Still needing a look')
    end

    it 'sends nothing when the organization has no owner email' do
      match('auto_matched')
      org.memberships.where(role: 'owner').destroy_all

      expect(described_class.list_ready(list.reload).message).to be_a(ActionMailer::Base::NullMail)
    end
  end
end
