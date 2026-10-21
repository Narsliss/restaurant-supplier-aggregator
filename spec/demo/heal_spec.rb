# frozen_string_literal: true

require_relative 'demo_spec_helper'

RSpec.describe DemoMode::Heal do
  let(:user) { create(:user, :with_organization) }
  let(:org) { user.current_organization }

  context 'with demo mode off' do
    it 'does nothing at all' do
      supplier = create(:supplier, :checkout_enabled)

      described_class.run!
      described_class.run_once_today

      expect(supplier.reload.checkout_enabled).to be(true)
    end
  end

  context 'with demo mode on' do
    include_context 'demo mode on'

    it 'replaces every saved login with a placeholder' do
      org.update!(name: 'Bella Vista Restaurant Group')
      cred = create(:supplier_credential, user: user, supplier: create(:supplier), username: 'real@restaurant.com',
                                          password: 'RealPassword!', session_data: '{"cookies":[{"name":"auth"}]}',
                                          trusted_device_token: 'real-token', status: 'expired')

      described_class.run!

      cred.reload
      expect(cred.username).to eq('orders@bellavista.demo')
      expect(cred.password).to eq('demo-password')
      expect(cred.session_data).to eq('{"demo":true}')
      expect(cred.trusted_device_token).to be_nil
      expect(cred.status).to eq('active')
    end

    it 'replaces a login it cannot even decrypt (copied from another database)' do
      cred = create(:supplier_credential, user: user, supplier: create(:supplier))
      cred.update_columns(encrypted_username: Base64.strict_encode64('x' * 32),
                          encrypted_password: Base64.strict_encode64('y' * 32))
      expect(cred.reload.safe_username).to be_nil

      described_class.run!

      expect(cred.reload.username).to start_with('orders@')
      expect(cred.password).to eq('demo-password')
    end

    it 'keeps no password for a code-only supplier' do
      cred = create(:supplier_credential, user: user, supplier: create(:supplier, :two_fa), password: 'x')

      described_class.run!

      expect(cred.reload.password).to be_nil
    end

    it "replaces an email supplier's real order address" do
      supplier = create(:supplier, :email, name: 'Blue Ribbon', contact_email: 'someone.real@hotmail.com')

      described_class.run!

      expect(supplier.reload.contact_email).to eq('orders@blueribbon.demo')
    end

    it 'turns checkout off for every supplier' do
      supplier = create(:supplier, :checkout_enabled)

      described_class.run!

      expect(supplier.reload.checkout_enabled).to be(false)
    end

    it 'unsticks matched lists the missing worker left processing' do
      matched = create(:aggregated_list, organization: org, created_by: user, match_status: 'matching',
                                         catalog_search_status: 'searching')
      ProductMatch.create!(aggregated_list: matched)
      empty = create(:aggregated_list, organization: org, created_by: user, match_status: 'matching')

      described_class.run!

      expect(matched.reload.match_status).to eq('matched')
      expect(matched.catalog_search_status).to eq('completed')
      expect(empty.reload.match_status).to eq('pending')
    end

    it 'finishes orders stuck checking prices or submitting' do
      supplier = create(:supplier)
      checking = create(:order, user: user, supplier: supplier, organization: org)
      create(:order_item, order: checking)
      checking.start_verification!
      placing = create(:order, user: user, supplier: supplier, organization: org, status: 'processing')
      create(:order_item, order: placing)

      described_class.run!

      expect(checking.reload.status).to eq('draft')
      expect(placing.reload.status).to eq('submitted')
    end

    it 'gives fresh delivery days to any login holding old ones, and none to a login without' do
      stale = create(:supplier_credential, user: user, supplier: create(:supplier),
                                           available_delivery_dates: %w[2026-08-14 2026-08-17])
      none = create(:supplier_credential, user: user, supplier: create(:supplier), available_delivery_dates: [])

      described_class.run!

      expect(stale.reload.available_delivery_dates).to eq(DemoMode::Simulator.delivery_dates)
      expect(none.reload.available_delivery_dates).to eq([])
    end

    it 'empties the queue jobs were waiting in for a worker' do
      SolidQueue::Job.create!(class_name: 'PlaceOrderJob', queue_name: 'critical', arguments: {})

      described_class.run!

      expect(SolidQueue::Job.count).to eq(0)
    end

    it 'moves order history forward so the newest placed order is today' do
      supplier = create(:supplier)
      placed = create(:order, :submitted, user: user, supplier: supplier, organization: org)
      placed.update_columns(created_at: 10.days.ago, submitted_at: 10.days.ago, delivery_date: 8.days.ago.to_date)
      older = create(:order, :submitted, user: user, supplier: supplier, organization: org)
      older.update_columns(created_at: 40.days.ago)
      recent_draft = create(:order, :draft, user: user, supplier: supplier, organization: org)
      recent_draft.update_columns(created_at: 2.days.ago)
      old_failure = create(:order, :failed, user: user, supplier: supplier, organization: org)
      old_failure.update_columns(created_at: 12.days.ago, delivery_date: 11.days.ago.to_date)

      described_class.run!

      expect(placed.reload.created_at.to_date).to eq(Date.current)
      expect(placed.delivery_date).to eq(2.days.from_now.to_date)
      expect(older.reload.created_at.to_date).to eq(30.days.ago.to_date)
      expect(recent_draft.reload.created_at.to_date).to eq(2.days.ago.to_date)
      expect(old_failure.reload.delivery_date).to eq(11.days.ago.to_date)
    end

    it 'runs once a day from the first request, in the background' do
      allow(Thread).to receive(:new)
      described_class.instance_variable_set(:@last_run_on, nil)

      described_class.run_once_today
      described_class.run_once_today

      expect(Thread).to have_received(:new).once
    ensure
      described_class.instance_variable_set(:@last_run_on, nil)
    end
  end
end
