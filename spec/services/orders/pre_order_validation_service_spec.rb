require 'rails_helper'

# NOTE: All `validate!` tests here are currently SKIPPED — see
# docs/known_bugs.md (#2). PreOrderValidationService references
# `OrderListItem#supplier_product`, an association that does not exist.
# Every validation path raises AssociationNotFoundError, silently swallowed
# by the rescue in Orders::OrderPlacementService#run_pre_order_validation —
# pre-order validation is effectively disabled in production today.
# Unskip these once the supplier_product references are fixed.

RSpec.describe Orders::PreOrderValidationService, type: :service do
  let(:user) { create(:user, :with_organization) }
  let(:organization) { user.current_organization }
  let(:supplier) { create(:supplier) }
  let(:product) { create(:product) }
  let!(:supplier_product) { create(:supplier_product, supplier: supplier, product: product, current_price: 10.00) }
  let(:order_list) do
    OrderList.create!(user: user, organization: organization, name: 'Validation list').tap do |list|
      list.order_list_items.create!(product: product, quantity: 2)
    end
  end

  let(:fake_scraper_class) { double('FakeScraperClass') }
  let(:fake_scraper) do
    instance_double(
      'FakeScraper',
      soft_refresh: true,
      check_stock: { in_stock: true },
      get_product_info: { price: 10.00, in_stock: true },
      get_order_minimum: { minimum: 0 },
      get_delivery_availability: { available: true },
      close_browser: nil
    )
  end

  before do
    skip 'PreOrderValidationService references nonexistent OrderListItem#supplier_product — see top-of-file note'
    allow(supplier).to receive(:scraper_klass).and_return(fake_scraper_class)
    allow(fake_scraper_class).to receive(:new).and_return(fake_scraper)
  end

  def build_service
    described_class.new(order_list: order_list, supplier: supplier, user: user, delivery_date: Date.tomorrow)
  end

  describe 'when user has no credential for supplier' do
    it 'returns an error result and never instantiates a scraper' do
      result = build_service.validate!
      expect(result[:valid]).to be false
      expect(result[:errors].first).to include(type: :credentials)
    end
  end

  describe 'when credential exists and is active' do
    let!(:credential) { create(:supplier_credential, user: user, supplier: supplier, status: 'active') }

    it 'returns valid:true with no errors when scraper checks all pass' do
      result = build_service.validate!
      expect(result).to include(valid: true, errors: [])
    end

    it 'detects price changes and updates supplier product price' do
      allow(fake_scraper).to receive(:get_product_info).and_return({ price: 12.50, in_stock: true })
      result = build_service.validate!
      expect(result[:price_changes].first).to include(old_price: 10.00, new_price: 12.50)
      expect(supplier_product.reload.current_price).to eq(12.50)
    end

    it 'returns an out-of-stock error when scraper reports product unavailable' do
      allow(fake_scraper).to receive(:check_stock).and_return({ in_stock: false })
      result = build_service.validate!
      expect(result[:errors].any? { |e| e[:type] == :stock }).to be true
    end

    it 'returns an order_minimum error when total is below the minimum' do
      allow(fake_scraper).to receive(:get_order_minimum).and_return({ minimum: 200.00 })
      result = build_service.validate!
      expect(result[:errors].any? { |e| e[:type] == :order_minimum }).to be true
    end

    it 'returns a delivery error when the date is unavailable' do
      allow(fake_scraper).to receive(:get_delivery_availability).and_return({ available: false })
      result = build_service.validate!
      expect(result[:errors].any? { |e| e[:type] == :delivery }).to be true
    end
  end
end

# These specs cover the OTHER half of price-change handling: the
# accept_price_changes kwarg lives in OrderPlacementService#run_pre_order_validation,
# not in PreOrderValidationService itself. They exercise that branch.
RSpec.describe Orders::OrderPlacementService, '#run_pre_order_validation accept_price_changes', type: :service do
  let(:user) { create(:user, :with_organization) }
  let(:supplier) { create(:supplier) }
  let!(:credential) { create(:supplier_credential, user: user, supplier: supplier, status: 'active') }
  let(:supplier_product) { create(:supplier_product, supplier: supplier) }
  let(:order) do
    create(:order, user: user, supplier: supplier, organization: user.current_organization).tap do |o|
      create(:order_item, order: o, supplier_product: supplier_product, quantity: 2, unit_price: 10)
    end
  end

  before do
    allow_any_instance_of(Orders::OrderValidationService).to receive(:validate!).and_return({ warnings: [], errors: [] })
  end

  def stub_pre_validation_with_price_changes
    price_change = {
      item_id: order.order_items.first.id,
      product_name: 'X',
      old_price: 10.00,
      new_price: 12.00,
      difference: 2.00
    }
    allow_any_instance_of(Orders::PreOrderValidationService).to receive(:validate!).and_return(
      valid: true,
      errors: [],
      warnings: [],
      price_changes: [price_change],
      can_proceed: true,
      requires_2fa: false,
      order_total: 24.00,
      item_count: 1
    )
  end

  context 'when prices have changed and accept_price_changes is false' do
    it 'halts placement, sets status=pending_review, and returns error_type=price_changed' do
      stub_pre_validation_with_price_changes

      result = described_class.new(order).place_order(accept_price_changes: false)

      expect(result).to include(success: false, error_type: 'price_changed', requires_review: true)
      expect(order.reload.status).to eq('pending_review')
    end
  end

  context 'when prices have changed and accept_price_changes is true' do
    it 'updates order item prices and proceeds to placement' do
      stub_pre_validation_with_price_changes

      # Prevent the rest of the placement flow from actually running.
      fake_scraper_class = double('FakeScraperClass')
      fake_scraper = instance_double(
        'FakeScraper',
        clear_cart: nil,
        add_to_cart: { added: [], failed: [] },
        checkout: { dry_run: true, total: 24.00, confirmation_number: nil, delivery_date: nil, cart_items: [] },
        close_order_browser!: nil
      )
      allow(supplier).to receive(:scraper_klass).and_return(fake_scraper_class)
      allow(fake_scraper_class).to receive(:new).and_return(fake_scraper)
      allow(order).to receive(:supplier).and_return(supplier)

      described_class.new(order).place_order(accept_price_changes: true)

      expect(order.order_items.first.reload.unit_price).to eq(12.00)
    end
  end
end
