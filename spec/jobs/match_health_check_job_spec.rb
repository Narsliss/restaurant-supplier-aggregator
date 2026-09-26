require 'rails_helper'

# The daily check that would have caught Sep 15 2026 the next morning: rows
# that lost every product, and chefs' order-list entries left pointing at them.
RSpec.describe MatchHealthCheckJob do
  include ActiveJob::TestHelper

  let!(:admin) { User.super_admin || create(:user, :super_admin) }
  let(:user) { create(:user, :with_organization) }
  let(:org) { user.current_organization }
  let(:location) { create(:location, organization: org, user: user) }
  let(:aggregated_list) { create(:aggregated_list, organization: org, location_id: location.id) }
  let(:order_list) { OrderList.create!(user: user, name: 'Weekly', location: location, organization_id: org.id) }

  def full_row
    row = create(:product_match, aggregated_list: aggregated_list, match_status: 'confirmed')
    create(:product_match_item, product_match: row)
    row
  end

  def empty_row(status: 'confirmed', name: 'Sopressata Salami')
    create(:product_match, aggregated_list: aggregated_list, match_status: status, canonical_name: name)
  end

  def run_check
    perform_enqueued_jobs { described_class.perform_now }
    ActionMailer::Base.deliveries
  end

  before { ActionMailer::Base.deliveries.clear }

  it 'reports the current state on the very first check' do
    row = empty_row
    OrderListItem.create!(order_list: order_list, product_match: row)
    full_row

    mails = run_check

    expect(mails.size).to eq(1)
    expect(mails.last.to).to eq([admin.email])
    expect(mails.last.subject).to include('1 empty rows', '1 order-list entries', 'first check')
    expect(mails.last.body.encoded).to include('Sopressata Salami', 'Weekly')
  end

  it 'stays quiet when nothing got worse since the last check' do
    empty_row
    run_check
    ActionMailer::Base.deliveries.clear

    expect(run_check).to be_empty
  end

  it 'reports only what is new since the last check, with the recorded cause' do
    empty_row(name: 'Old Empty')
    run_check
    ActionMailer::Base.deliveries.clear

    newly = full_row
    newly.update!(canonical_name: 'Ground Cumin')
    MatchChange.as('chef_edit') { newly.product_match_items.each(&:destroy!) }

    mails = run_check

    expect(mails.size).to eq(1)
    expect(mails.last.subject).to include('1 newly empty rows')
    expect(mails.last.body.encoded).to include('Ground Cumin', 'chef_edit')
    expect(mails.last.body.encoded).not_to include('Old Empty')
  end

  it 'ignores rows the chef removed from the list' do
    empty_row(status: 'rejected')

    expect(run_check).to be_empty
    expect(MatchHealthCheck.last.empty_row_ids).to eq([])
  end
end
