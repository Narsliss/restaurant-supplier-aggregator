# frozen_string_literal: true

require_relative 'demo_spec_helper'

RSpec.describe DemoMode::Simulator do
  include_context 'demo mode on'
  include_context 'demo jobs inline'

  let(:user) { create(:user, :with_organization) }
  let(:org) { user.current_organization }

  before do
    # Nothing here may reach the supplier-facing code.
    expect(Authentication::SessionManager).not_to receive(:new)
    expect(Orders::OrderPlacementService).not_to receive(:new)
    expect(Orders::PriceVerificationService).not_to receive(:new)
  end

  describe 'supplier logins' do
    let(:supplier) { create(:supplier, :two_fa) }
    let(:cred) do
      create(:supplier_credential, user: user, supplier: supplier, status: 'pending', last_login_at: 3.days.ago)
    end

    it 'Validate connects the login and finishes its import' do
      ValidateCredentialsJob.perform_later(cred.id)

      cred.reload
      expect(cred.status).to eq('active')
      expect(cred.last_login_at).to be_within(5.seconds).of(Time.current)
      expect(cred.importing).to be(false)
      expect(cred.last_import_at).to be_present
    end

    it 'never keeps what was typed into the login form' do
      typed = create(:supplier_credential, user: user, supplier: create(:supplier), status: 'pending',
                                           username: 'chef@realrestaurant.com', password: 'RealPassword!')

      ValidateCredentialsJob.perform_later(typed.id)

      typed.reload
      expect(typed.username).to end_with('.demo')
      expect(typed.password).to eq('demo-password')
    end

    it 'Sysco goes through its combined import and gets delivery days' do
      sysco = Supplier.find_by(code: 'sysco') || create(:supplier, code: 'sysco', name: 'Sysco')
      sysco_cred = create(:supplier_credential, user: user, supplier: sysco, status: 'pending')

      ValidateCredentialsJob.perform_later(sysco_cred.id)

      sysco_cred.reload
      expect(sysco_cred.status).to eq('active')
      expect(sysco_cred.importing).to be(false)
      expect(sysco_cred.available_delivery_dates).to eq(described_class.delivery_dates)
    end

    it 'Import marks the catalog freshly synced' do
      product = create(:supplier_product, supplier: supplier, last_scraped_at: 2.months.ago)
      cred.update!(status: 'active', importing: true)

      ImportSupplierProductsJob.perform_later(supplier.id, cred.id)

      expect(product.reload.last_scraped_at).to be_within(5.seconds).of(Time.current)
      expect(cred.reload.importing).to be(false)
    end
  end

  describe 'delivery days' do
    it 'offers the next two weeks without Sundays' do
      dates = described_class.delivery_dates(from: Date.new(2026, 10, 20)).map { |d| Date.parse(d) }

      expect(dates.first).to eq(Date.new(2026, 10, 21))
      expect(dates).to all(satisfy { |d| !d.sunday? })
      expect(dates.size).to eq(12)
    end
  end

  describe 'orders' do
    let(:supplier) { create(:supplier, :checkout_enabled) }
    let(:order) { create(:order, user: user, supplier: supplier, organization: org) }
    let!(:item) { create(:order_item, order: order, quantity: 3, unit_price: 12.5, line_total: 37.5) }

    it 'confirms every price on review and saves the order as a draft' do
      order.start_verification!

      PriceVerificationJob.perform_later(order.id)

      order.reload
      expect(order.status).to eq('draft')
      expect(order.verification_status).to eq('verified')
      expect(order.verified_total).to eq(37.5)
      expect(item.reload.verified_price).to eq(12.5)
    end

    it 'leaves an order alone that is no longer being checked' do
      PriceVerificationJob.perform_later(order.id)

      expect(order.reload.status).to eq('pending')
    end

    it 'submits with a demo confirmation number and no supplier changes' do
      order.start_placement!

      PlaceOrderJob.perform_later(order.id)

      order.reload
      expect(order.status).to eq('submitted')
      expect(order.confirmation_number).to start_with('DEMO-')
      expect(order.total_amount).to eq(37.5)
      expect(order.exceptions_checked_at).to be_present
      expect(order.supplier_exceptions).to eq([])
    end

    it 'never submits an order that is not being placed' do
      order.update!(status: 'cancelled')

      PlaceOrderJob.perform_later(order.id)

      expect(order.reload.status).to eq('cancelled')
    end
  end
end
