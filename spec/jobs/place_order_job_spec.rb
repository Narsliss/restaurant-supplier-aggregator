require 'rails_helper'

RSpec.describe PlaceOrderJob, type: :job do
  let(:user) { create(:user, :with_organization) }
  let(:supplier) { create(:supplier) }
  let(:order) { create(:order, user: user, supplier: supplier, organization: user.current_organization) }

  describe 'idempotency guard' do
    it 'returns without invoking placement when order is already submitted' do
      order.update!(status: 'submitted', submitted_at: Time.current)

      expect(Orders::OrderPlacementService).not_to receive(:new)

      described_class.new.perform(order.id)
    end

    it 'returns without invoking placement when order is already confirmed' do
      order.update!(status: 'confirmed', submitted_at: 1.day.ago, confirmed_at: Time.current)

      expect(Orders::OrderPlacementService).not_to receive(:new)

      described_class.new.perform(order.id)
    end

    it 'returns without invoking placement when order is dry_run_complete' do
      order.update!(status: 'dry_run_complete', submitted_at: Time.current)

      expect(Orders::OrderPlacementService).not_to receive(:new)

      described_class.new.perform(order.id)
    end

    it 'proceeds when order is in a non-terminal state' do
      service = instance_double(Orders::OrderPlacementService, place_order: { success: true, dry_run: true })
      expect(Orders::OrderPlacementService).to receive(:new).with(order).and_return(service)

      described_class.new.perform(order.id)
    end
  end

  describe 'discard on missing order' do
    # Documents a real bug: the bare `rescue => e` in perform catches
    # ActiveRecord::RecordNotFound before `discard_on` can fire, then calls
    # `order.update!` on a nil `order`, raising NoMethodError instead of
    # discarding cleanly. See docs/known_bugs.md.
    it 'discards instead of raising when the order has been deleted' do
      missing_id = order.id
      order.destroy!

      expect {
        described_class.perform_now(missing_id)
      }.not_to raise_error
    end
  end

  describe 'demo mode' do
    around do |example|
      ENV['DEMO_MODE'] = 'true'
      example.run
    ensure
      ENV.delete('DEMO_MODE')
    end

    it 'marks the order submitted without invoking the real scraper' do
      expect(Orders::OrderPlacementService).not_to receive(:new)

      described_class.new.perform(order.id)

      expect(order.reload.status).to eq('submitted')
      expect(order.submitted_at).to be_present
    end
  end

  describe 'success path' do
    it 'does not send owner notification on dry_run' do
      service = instance_double(Orders::OrderPlacementService, place_order: { success: true, dry_run: true })
      allow(Orders::OrderPlacementService).to receive(:new).and_return(service)

      expect(OrderMailer).not_to receive(:order_placed_notification)

      described_class.new.perform(order.id)
    end

    it 'enqueues owner notification when a non-owner user places a real order' do
      member = create(:user)
      create(:membership, user: member, organization: user.current_organization, role: 'manager')
      order.update!(user: member)

      service = instance_double(Orders::OrderPlacementService, place_order: { success: true })
      allow(Orders::OrderPlacementService).to receive(:new).and_return(service)

      mailer = double(deliver_later: true)
      expect(OrderMailer).to receive(:order_placed_notification).with(order).and_return(mailer)

      described_class.new.perform(order.id)
    end

    it 'does not notify when the placing user is the org owner' do
      service = instance_double(Orders::OrderPlacementService, place_order: { success: true })
      allow(Orders::OrderPlacementService).to receive(:new).and_return(service)

      expect(OrderMailer).not_to receive(:order_placed_notification)

      described_class.new.perform(order.id)
    end
  end

  describe 'rescue path (rescue-hazard pattern)' do
    it 're-raises and writes status:failed when the service raises' do
      service = instance_double(Orders::OrderPlacementService)
      allow(Orders::OrderPlacementService).to receive(:new).and_return(service)
      allow(service).to receive(:place_order).and_raise(StandardError, 'boom')

      expect {
        described_class.new.perform(order.id)
      }.to raise_error(StandardError, 'boom')

      expect(order.reload.status).to eq('failed')
      expect(order.error_message).to eq('boom')
    end
  end

  describe 'failure result handling (no rescue)' do
    it 'does not mutate status:failed when the service returns a structured failure' do
      service = instance_double(
        Orders::OrderPlacementService,
        place_order: { success: false, error_type: 'price_changed', error: 'Prices changed' }
      )
      allow(Orders::OrderPlacementService).to receive(:new).and_return(service)

      described_class.new.perform(order.id)

      # The service is responsible for setting status (e.g., pending_review).
      # The job's failure handler only logs — it must not stomp the status.
      expect(order.reload.status).not_to eq('failed')
    end
  end
end
