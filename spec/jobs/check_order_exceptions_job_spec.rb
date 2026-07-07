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
end
