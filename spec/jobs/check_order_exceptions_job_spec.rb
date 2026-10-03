require 'rails_helper'

RSpec.describe CheckOrderExceptionsJob, type: :job do
  let(:user) { create(:user, :with_organization) }
  let(:supplier) { Supplier.find_by(code: 'usfoods') || create(:supplier, code: 'usfoods') }
  let(:order) do
    create(:order, user: user, supplier: supplier, organization: user.current_organization,
                   status: 'submitted', submitted_at: 1.minute.ago, confirmation_number: 'TCW1')
  end

  def stub_checker(result)
    checker = instance_double(Orders::SupplierExceptionChecker, check!: result)
    allow(Orders::SupplierExceptionChecker).to receive(:new).with(order).and_return(checker)
  end

  it 'does nothing for an order that is not submitted/confirmed' do
    order.update!(status: 'failed')
    expect(Orders::SupplierExceptionChecker).not_to receive(:new)
    described_class.perform_now(order.id)
  end

  it 're-polls when no exceptions are found yet on a fresh order' do
    stub_checker([])
    expect { described_class.perform_now(order.id, 1) }
      .to have_enqueued_job(described_class).with(order.id, 2)
  end

  it 'stops re-polling once exceptions are found' do
    stub_checker([{ 'type' => 'out_of_stock', 'sku' => 'X' }])
    expect { described_class.perform_now(order.id, 1) }.not_to have_enqueued_job(described_class)
  end

  it 'stops re-polling after the max attempts' do
    stub_checker([])
    expect { described_class.perform_now(order.id, described_class::MAX_ATTEMPTS) }
      .not_to have_enqueued_job(described_class)
  end

  it 'does not re-poll an order submitted long ago' do
    order.update!(submitted_at: 1.hour.ago)
    stub_checker([])
    expect { described_class.perform_now(order.id, 1) }.not_to have_enqueued_job(described_class)
  end

  # Order #332: US Foods shorted the vinegar and chevre after our first-minute
  # check. The evening/morning sweeps run this with notify: true.
  describe 'emailing the chef + owner(s) when US Foods changed the order' do
    let(:chef) { create(:user).tap { |u| create(:membership, user: u, organization: user.current_organization, role: 'chef') } }
    let(:exceptions) { [{ sku: '4336327', type: 'out_of_stock', ordered: 1, filled: 0, message: 'Out of stock: 0 of 1 reserved' }] }

    around do |example|
      original = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rails.cache = original
    end

    before do
      ActionMailer::Base.deliveries.clear
      order.update!(user: chef, delivery_date: Date.new(2026, 9, 28),
                    supplier_exceptions: exceptions.map(&:stringify_keys))
    end

    it 'emails the chef and the owner' do
      stub_checker(exceptions)

      described_class.perform_now(order.id, described_class::MAX_ATTEMPTS, true)

      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to contain_exactly(chef.email, user.email)
      expect(mail.subject).to eq("[EnPlace Pro] #{order.display_supplier_name} changed your order for Mon Sep 28: 1 item not coming")
      expect(mail.body.to_s).to include('4336327', 'Out of stock', '0 of 1 coming', 'https://order.usfoods.com/desktop/order')
    end

    it 'does not email the same changes twice (evening, then morning)' do
      stub_checker(exceptions)

      2.times { described_class.perform_now(order.id, described_class::MAX_ATTEMPTS, true) }

      expect(ActionMailer::Base.deliveries.size).to eq(1)
    end

    it 'emails again when something new changed' do
      stub_checker(exceptions)
      described_class.perform_now(order.id, described_class::MAX_ATTEMPTS, true)

      more = exceptions + [{ sku: '4917936', type: 'out_of_stock', ordered: 1, filled: 0, message: 'x' }]
      stub_checker(more)
      described_class.perform_now(order.id, described_class::MAX_ATTEMPTS, true)

      expect(ActionMailer::Base.deliveries.size).to eq(2)
    end

    it 'keeps the first-minute check in the app only' do
      stub_checker(exceptions)

      described_class.perform_now(order.id, 1)

      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'sends nothing when US Foods changed nothing' do
      stub_checker([])

      described_class.perform_now(order.id, described_class::MAX_ATTEMPTS, true)

      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end
end

RSpec.describe UsFoodsExceptionSweepJob, type: :job do
  let(:user) { create(:user, :with_organization) }
  let(:usf) { Supplier.find_by(code: 'usfoods') || create(:supplier, code: 'usfoods') }
  let(:today) { Time.find_zone('America/New_York').today }

  def usf_order(delivery_date:, status: 'submitted', confirmation: 'abc-123')
    create(:order, user: user, supplier: usf, organization: user.current_organization,
                   status: status, delivery_date: delivery_date, confirmation_number: confirmation)
  end

  it "evening: re-checks tomorrow's US Foods orders, with notify" do
    tomorrow = usf_order(delivery_date: today + 1)
    usf_order(delivery_date: today)
    usf_order(delivery_date: today + 1, status: 'failed')
    usf_order(delivery_date: today + 1, confirmation: 'DRY-RUN-1')

    expect { described_class.perform_now('evening') }
      .to have_enqueued_job(CheckOrderExceptionsJob).with(tomorrow.id, CheckOrderExceptionsJob::MAX_ATTEMPTS, true).exactly(:once)
  end

  it "morning: re-checks today's US Foods orders" do
    todays = usf_order(delivery_date: today)

    expect { described_class.perform_now('morning') }
      .to have_enqueued_job(CheckOrderExceptionsJob).with(todays.id, CheckOrderExceptionsJob::MAX_ATTEMPTS, true)
  end
end
