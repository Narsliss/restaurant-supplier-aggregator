require 'rails_helper'

# ORDERING SAFETY (Oct 20 2026, docs/plan-order-placement-double-submit-and-account-lock.md).
#
# Gap 1: on a deploy Solid Queue 0.9.0 re-queues the running PlaceOrderJob
# (ClaimedExecution#release, bypassing limits_concurrency). If the first run
# died after the live submit went out, the re-run must never send it again.
#
# Gap 2: two placements that share a supplier account — a restaurant at a
# supplier, or a supplier login — must not run at once (shared carts).
#
# These drive the real job and OrderPlacementService against a fake supplier
# that records every cart call, with production's live-checkout path on.
RSpec.describe 'PlaceOrderJob: never twice, one at a time per supplier account' do
  let(:owner) { create(:user, :with_organization) }
  let(:org) { owner.current_organization }
  let(:noche) { create(:location, organization: org, user: owner, name: 'Noche') }
  let(:doro) { create(:location, organization: org, user: owner, name: "D'oro") }
  let(:supplier) { create(:supplier, checkout_enabled: true) }
  let!(:credential) do
    create(:supplier_credential, user: owner, supplier: supplier, location_id: noche.id, username: 'Alfio@Example.com')
  end
  let(:order) do
    create(:order, user: owner, supplier: supplier, organization: org, location: noche, status: 'processing').tap do |o|
      create(:order_item, order: o, supplier_product: create(:supplier_product, supplier: supplier), quantity: 2, unit_price: 10)
    end
  end

  # Records each supplier step. kill_at raises SimulatedWorkerKill at that
  # step — an Exception, so it escapes every rescue, like a killed thread.
  let(:scraper_class) do
    Class.new(Scrapers::BaseScraper) do
      class << self
        attr_accessor :calls, :kill_at, :on_verify, :on_submit
      end
      self.calls = []

      def clear_cart
        record(:clear_cart)
      end

      def add_to_cart(items, delivery_date: nil)
        record(:add_to_cart)
        { added: items.size, failed: [] }
      end

      def verify_cart_matches!(_items)
        self.class.on_verify&.call
        record(:verify)
      end

      def checkout(dry_run: false)
        raise ArgumentError, 'these examples place live orders' if dry_run

        submit_sent!
        self.class.on_submit&.call # the submit request itself
        record(:submit)
        { dry_run: false, confirmation_number: "CONF-#{self.class.calls.count(:submit)}", total: 20.0,
          delivery_date: nil, cart_items: [] }
      end

      private

      def record(step)
        self.class.calls << step
        raise SimulatedWorkerKill, "worker killed at #{step}" if self.class.kill_at == step

        true
      end
    end
  end

  def submits
    scraper_class.calls.count(:submit)
  end

  before do
    stub_const('SimulatedWorkerKill', Class.new(Exception))
    allow(Rails.env).to receive(:production?).and_return(true)
    allow_any_instance_of(Supplier).to receive(:scraper_klass).and_return(scraper_class)
    allow_any_instance_of(Orders::OrderValidationService).to receive(:validate!).and_return({ warnings: [], errors: [] })
    allow_any_instance_of(Orders::PreOrderValidationService).to receive(:validate!)
      .and_return({ valid: true, errors: [], warnings: [], price_changes: [], requires_2fa: false })
    allow(OrderFailureAlertJob).to receive(:schedule)
  end

  describe 'a deploy re-runs the job (gap 1)' do
    it 'never sends an order a second time once its live submit went out' do
      scraper_class.kill_at = :submit
      expect { PlaceOrderJob.perform_now(order.id) }.to raise_error(SimulatedWorkerKill)
      expect(submits).to eq(1)
      expect(order.reload.status).to eq('processing')

      scraper_class.kill_at = nil
      PlaceOrderJob.perform_now(order.id) # the copy Solid Queue put back on the queue

      expect(submits).to eq(1)
      expect(scraper_class.calls.count(:clear_cart)).to eq(1)
      expect(order.reload.submit_sent_at).to be_present
      expect(order.reload.status).to eq('pending_manual')
      expect(order.error_message).to include("may or may not have gone through. Check #{supplier.name} before reordering")
      expect(OrderFailureAlertJob).to have_received(:schedule).with(kind_of(Order), kind: 'unconfirmed')
    end

    it 'commits the marker before the submit request goes out' do
      marker_seen_by_the_request = :not_reached
      scraper_class.on_submit = -> { marker_seen_by_the_request = Order.where(id: order.id).pick(:submit_sent_at) }

      PlaceOrderJob.perform_now(order.id)

      expect(marker_seen_by_the_request).to be_present
      expect(order.reload).to have_attributes(status: 'submitted', confirmation_number: 'CONF-1')
    end

    it 'places the order normally when the first run died before anything was sent' do
      scraper_class.kill_at = :add_to_cart
      expect { PlaceOrderJob.perform_now(order.id) }.to raise_error(SimulatedWorkerKill)
      expect(order.reload.submit_sent_at).to be_nil

      scraper_class.kill_at = nil
      PlaceOrderJob.perform_now(order.id)

      expect(submits).to eq(1)
      expect(order.reload).to have_attributes(status: 'submitted', confirmation_number: 'CONF-1')
    end

    it 'leaves an order the supplier refused after the submit as it is' do
      order.update!(status: 'failed', submit_sent_at: 1.minute.ago,
                    error_message: "Not placed. #{supplier.name} did not accept the order.")

      PlaceOrderJob.perform_now(order.id)

      expect(scraper_class.calls).to be_empty
      expect(order.reload.status).to eq('failed')
      expect(order.error_message).to eq("Not placed. #{supplier.name} did not accept the order.")
    end

    it "leaves an unconfirmed order for the chef to check, even if a stale job runs" do
      order.update!(status: 'pending_manual', submit_sent_at: 1.minute.ago,
                    error_message: Orders::OrderPlacementService.unconfirmed_message(order))

      PlaceOrderJob.perform_now(order.id)

      expect(scraper_class.calls).to be_empty
      expect(order.reload.status).to eq('pending_manual')
    end

    it 'sends it again only when the chef starts a new attempt' do
      order.update!(status: 'pending', submit_sent_at: 1.minute.ago) # Retry after a clear refusal
      expect(order.start_placement!(error_message: nil)).to be(true)
      expect(order.reload.submit_sent_at).to be_nil

      PlaceOrderJob.perform_now(order.id)

      expect(submits).to eq(1)
      expect(order.reload.status).to eq('submitted')
    end

    it 'sends nothing when the marker cannot be written' do
      allow_any_instance_of(Order).to receive(:update_columns).and_raise(ActiveRecord::StatementInvalid, 'db down')

      PlaceOrderJob.perform_now(order.id)

      expect(scraper_class.calls).to include(:verify) # got as far as the submit
      expect(submits).to eq(0)
      expect(order.reload.status).to eq('failed')
      expect(order.error_message).to include('nothing was ordered')
    end

    it 'never places an order the chef cancelled while it waited in the queue' do
      order.update!(status: 'cancelled')

      PlaceOrderJob.perform_now(order.id)

      expect(scraper_class.calls).to be_empty
      expect(order.reload.status).to eq('cancelled')
    end
  end

  describe 'two placements on one supplier account (gap 2)' do
    # Another placement, mid-flight in another worker: its own database
    # connection holding the real Postgres advisory locks.
    let(:other_connection) { ApplicationRecord.connection_pool.checkout }

    after do
      @other_placement&.release
      ApplicationRecord.connection_pool.checkin(other_connection)
    end

    def another_placement_holds(location:, credential:)
      other_order = build(:order, user: credential.user, supplier: supplier, organization: org, location: location)
      @other_placement = Orders::SupplierAccountLock.new(other_order, credential)
      expect(@other_placement.acquire(connection: other_connection)).to be(true)
    end

    def expect_waiting_without_touching_the_supplier
      expect(scraper_class.calls).to be_empty
      expect(order.reload.status).to eq('processing')
      expect(PlaceOrderJob).to have_been_enqueued.with(order.id, hash_including(account_wait_since: kind_of(Integer)))
    end

    it "waits while another chef's login orders for the same restaurant" do
      chef = create(:user)
      chef_login = create(:supplier_credential, user: chef, supplier: supplier, location_id: noche.id,
                                                username: 'nate@example.com')
      another_placement_holds(location: noche, credential: chef_login)

      PlaceOrderJob.perform_now(order.id)

      expect_waiting_without_touching_the_supplier
    end

    it "waits while the owner's same login orders for another restaurant" do
      another_placement_holds(location: doro, credential: credential)

      PlaceOrderJob.perform_now(order.id)

      expect_waiting_without_touching_the_supplier
    end

    it 'counts one login on several connection rows as one login' do
      doro_row = create(:supplier_credential, user: owner, supplier: supplier, location_id: doro.id,
                                              username: ' alfio@example.com ')
      another_placement_holds(location: doro, credential: doro_row)

      PlaceOrderJob.perform_now(order.id)

      expect_waiting_without_touching_the_supplier
    end

    it 'runs alongside a placement for another restaurant on another login' do
      chef = create(:user)
      chef_login = create(:supplier_credential, user: chef, supplier: supplier, location_id: doro.id,
                                                username: 'nate@example.com')
      another_placement_holds(location: doro, credential: chef_login)

      PlaceOrderJob.perform_now(order.id)

      expect(submits).to eq(1)
      expect(order.reload.status).to eq('submitted')
    end

    it 'places the order on a later try, once the other placement is done' do
      another_placement_holds(location: doro, credential: credential)
      PlaceOrderJob.perform_now(order.id)
      expect(submits).to eq(0)

      @other_placement.release
      PlaceOrderJob.perform_now(order.id, account_wait_since: 20.seconds.ago.to_i)

      expect(submits).to eq(1)
      expect(order.reload.status).to eq('submitted')
    end

    it 'stops the order, with nothing sent, after waiting 10 minutes' do
      another_placement_holds(location: noche, credential: credential)

      PlaceOrderJob.perform_now(order.id, account_wait_since: 11.minutes.ago.to_i)

      expect(scraper_class.calls).to be_empty
      expect(order.reload.status).to eq('failed')
      expect(order.error_message).to eq(
        "Not placed. Another #{supplier.name} order for this restaurant or login was still going through, " \
        'so nothing was sent. Try again in a few minutes.'
      )
      expect(PlaceOrderJob).not_to have_been_enqueued
      expect(OrderFailureAlertJob).to have_received(:schedule).with(kind_of(Order), kind: 'not_placed')
    end

    it 'releases the account when the placement ends, and when it crashes' do
      PlaceOrderJob.perform_now(order.id)
      expect(Orders::SupplierAccountLock.new(order, credential).acquire(connection: other_connection)).to be(true)
      other_connection.execute('SELECT pg_advisory_unlock_all()')

      second = create(:order, user: owner, supplier: supplier, organization: org, location: noche, status: 'processing')
      create(:order_item, order: second, supplier_product: create(:supplier_product, supplier: supplier), quantity: 1, unit_price: 10)
      scraper_class.kill_at = :add_to_cart
      expect { PlaceOrderJob.perform_now(second.id) }.to raise_error(SimulatedWorkerKill)

      expect(Orders::SupplierAccountLock.new(second, credential).acquire(connection: other_connection)).to be(true)
      other_connection.execute('SELECT pg_advisory_unlock_all()')
    end

    it 'sends nothing if the account hold was lost before the submit (a silent reconnect)' do
      scraper_class.on_verify = -> { ApplicationRecord.connection.execute('SELECT pg_advisory_unlock_all()') }

      PlaceOrderJob.perform_now(order.id)

      expect(submits).to eq(0)
      expect(order.reload.status).to eq('failed')
      expect(order.error_message).to include('lost its hold')
      expect(order.submit_sent_at).to be_nil
    end
  end
end
