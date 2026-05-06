require 'rails_helper'

# CRITICAL: this spec is a tripwire for ordering safety.
#
# The onboarding wizard's contract is that running it end-to-end creates rows
# in EXACTLY ONE table (onboarding_progresses) plus optionally stamps
# users.onboarding_dismissed_at. It must never write to ordering-adjacent
# tables (orders, order_items, supplier_2fa_requests, etc.) directly.
#
# If this spec fails, the wizard has gained a write path it shouldn't have.
# Investigate before merging.
RSpec.describe 'Onboarding wizard — ordering safety regression', type: :request do
  let(:user) { create(:user, :with_organization) }
  before { sign_in user }

  WATCHED_MODELS = [
    Order,
    OrderItem,
    OrderList,
    SupplierCredential,
    Supplier2faRequest,
    AggregatedList,
    Location,
    Organization,        # already exists from the factory; we assert delta is zero
    OrganizationInvitation,
    Membership,
    User,                # the user already exists; delta should still be zero
  ].freeze

  it 'a full wizard run creates zero rows in any application data table' do
    baselines = WATCHED_MODELS.index_with(&:count)

    # Walk through every wizard endpoint as the client controller would.
    get  onboarding_progress_path
    post advance_onboarding_progress_path,  params: { next_step: 'organization' }
    post advance_onboarding_progress_path,  params: { next_step: 'restaurant' }
    post advance_onboarding_progress_path,  params: { next_step: 'team' }
    post advance_onboarding_progress_path,  params: { next_step: 'suppliers' }
    post advance_onboarding_progress_path,  params: { next_step: 'train-orderlists' }
    post advance_onboarding_progress_path,  params: { next_step: 'train-neworder' }
    post advance_onboarding_progress_path,  params: { next_step: 'train-matching' }
    post advance_onboarding_progress_path,  params: { next_step: 'train-promote' }
    post advance_onboarding_progress_path,  params: { next_step: 'train-orderhistory' }
    post advance_onboarding_progress_path,  params: { next_step: 'train-reports' }
    post complete_onboarding_progress_path
    post restart_onboarding_progress_path
    post skip_onboarding_progress_path

    # Onboarding's own table SHOULD have grown by exactly one row.
    expect(OnboardingProgress.count).to eq(1)

    # Every other model must be unchanged.
    WATCHED_MODELS.each do |model|
      delta = model.count - baselines[model]
      expect(delta).to eq(0), "expected #{model.name} count to be unchanged, got delta=#{delta}"
    end
  end

  it 'never invokes OrderPlacementService or any scraper' do
    expect(Orders::OrderPlacementService).not_to receive(:new)
    expect(Orders::EmailOrderPlacementService).not_to receive(:new)
    expect_any_instance_of(Scrapers::BaseScraper).not_to receive(:login) if defined?(Scrapers::BaseScraper)

    get  onboarding_progress_path
    post advance_onboarding_progress_path, params: { next_step: 'organization' }
    post complete_onboarding_progress_path
  end

  it 'does not enqueue any background jobs' do
    expect {
      get  onboarding_progress_path
      post advance_onboarding_progress_path, params: { next_step: 'organization' }
      post complete_onboarding_progress_path
      post skip_onboarding_progress_path
      post restart_onboarding_progress_path
    }.not_to change { SolidQueue::Job.count }
  end
end
