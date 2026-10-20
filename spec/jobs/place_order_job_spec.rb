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
      expect(Orders::OrderPlacementService).to receive(:new)
        .with(order, account_lock: kind_of(Orders::SupplierAccountLock)).and_return(service)

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
    def crashing_service(submit_sent: false, &before_crash)
      service = instance_double(Orders::OrderPlacementService, submit_sent?: submit_sent)
      allow(Orders::OrderPlacementService).to receive(:new).and_return(service)
      allow(service).to receive(:place_order) do
        before_crash&.call
        raise StandardError, 'boom'
      end
      service
    end

    it 're-raises and writes a plain not-placed message when nothing was sent' do
      crashing_service

      expect {
        described_class.new.perform(order.id)
      }.to raise_error(StandardError, 'boom')

      expect(order.reload.status).to eq('failed')
      expect(order.error_message).to eq(
        "Not placed. Something went wrong before anything was sent to #{supplier.name}. " \
        "Try again; if it fails twice, order on #{supplier.name}'s site."
      )
    end

    # Phase 5 (Oct 19 2026): "failed" after the submit went out invites a
    # second order; the supplier may already have this one.
    it 'calls the order unconfirmed when the crash came after the live submit' do
      crashing_service(submit_sent: true) { order.update!(status: 'processing') }
      expect(OrderFailureAlertJob).to receive(:schedule).with(kind_of(Order), kind: 'unconfirmed')

      expect { described_class.new.perform(order.id) }.to raise_error(StandardError, 'boom')

      expect(order.reload.status).to eq('pending_manual')
      expect(order.error_message).to include("may or may not have gone through. Check #{supplier.name} before reordering")
    end

    it 'never touches an order that was placed before the crash (order 102)' do
      crashing_service(submit_sent: true) { order.update!(status: 'submitted', submitted_at: Time.current, confirmation_number: 'C1') }

      expect { described_class.new.perform(order.id) }.to raise_error(StandardError, 'boom')

      expect(order.reload).to have_attributes(status: 'submitted', confirmation_number: 'C1')
    end

    # Order placement safety (Oct 20 2026): the persisted marker counts too.
    it 'calls the order unconfirmed when its recorded submit went out before the crash' do
      crashing_service { order.update!(status: 'processing', submit_sent_at: Time.current) }
      expect(OrderFailureAlertJob).to receive(:schedule).with(kind_of(Order), kind: 'unconfirmed')

      expect { described_class.new.perform(order.id) }.to raise_error(StandardError, 'boom')

      expect(order.reload.status).to eq('pending_manual')
    end

    it 'leaves an order an earlier run sent exactly as it was when this run crashes' do
      order.update!(status: 'pending_manual', submit_sent_at: 1.minute.ago, error_message: 'Check first.')
      allow_any_instance_of(Order).to receive(:reload).and_wrap_original do |original, *args|
        @reloads = (@reloads || 0) + 1
        raise ActiveRecord::ConnectionNotEstablished, 'db blip' if @reloads == 1

        original.call(*args)
      end

      expect { described_class.new.perform(order.id) }.to raise_error(ActiveRecord::ConnectionNotEstablished)

      expect(Order.find(order.id)).to have_attributes(status: 'pending_manual', error_message: 'Check first.')
    end

    it 'keeps an outcome the service already wrote during this run' do
      crashing_service { order.update!(status: 'failed', error_message: 'Not placed. EnPlace isn\'t connected to Sysco.') }

      expect { described_class.new.perform(order.id) }.to raise_error(StandardError, 'boom')

      expect(order.reload.error_message).to eq("Not placed. EnPlace isn't connected to Sysco.")
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

  # Order #386 (Oct 2026): a failed order must never go unnoticed.
  describe 'not-placed alert' do
    def stub_service(result, status_after:)
      service = instance_double(Orders::OrderPlacementService)
      allow(Orders::OrderPlacementService).to receive(:new).and_return(service)
      allow(service).to receive(:place_order) { order.update!(status: status_after); result }
    end

    it 'schedules the alert when placement ends without placing the order' do
      stub_service({ success: false, error_type: 'items_unavailable' }, status_after: 'failed')

      expect(OrderFailureAlertJob).to receive(:schedule).with(kind_of(Order), kind: 'not_placed')

      described_class.new.perform(order.id)
    end

    it 'marks an unconfirmed submit as such' do
      stub_service({ success: false, error_type: 'unconfirmed' }, status_after: 'pending_manual')

      expect(OrderFailureAlertJob).to receive(:schedule).with(kind_of(Order), kind: 'unconfirmed')

      described_class.new.perform(order.id)
    end

    it 'does not alert when the order was placed' do
      stub_service({ success: true }, status_after: 'submitted')

      expect(OrderFailureAlertJob).not_to receive(:schedule)

      described_class.new.perform(order.id)
    end

    it 'alerts when the service raises' do
      service = instance_double(Orders::OrderPlacementService, submit_sent?: false)
      allow(Orders::OrderPlacementService).to receive(:new).and_return(service)
      allow(service).to receive(:place_order).and_raise(StandardError, 'boom')

      expect(OrderFailureAlertJob).to receive(:schedule).with(kind_of(Order), kind: 'not_placed')

      expect { described_class.new.perform(order.id) }.to raise_error(StandardError, 'boom')
    end

    it 'never lets alerting change the order or raise' do
      stub_service({ success: false, error_type: 'price_changed' }, status_after: 'pending_review')
      allow(OrderFailureAlertJob).to receive(:schedule).and_raise(StandardError, 'mail down')

      expect { described_class.new.perform(order.id) }.not_to raise_error
      expect(order.reload.status).to eq('pending_review')
    end
  end
end
