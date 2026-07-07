require 'rails_helper'

RSpec.describe Orders::OrderPlacementService, type: :service do
  let(:user) { create(:user, :with_organization) }
  let(:supplier) { create(:supplier, checkout_enabled: false) }
  let!(:credential) { create(:supplier_credential, user: user, supplier: supplier, status: 'active') }
  let(:supplier_product) { create(:supplier_product, supplier: supplier) }
  let(:order) do
    create(:order, user: user, supplier: supplier, organization: user.current_organization).tap do |o|
      create(:order_item, order: o, supplier_product: supplier_product, quantity: 2, unit_price: 10)
    end
  end

  let(:fake_scraper_class) { double('FakeScraperClass') }
  let(:fake_scraper) do
    instance_double(
      'FakeScraper',
      clear_cart: nil,
      add_to_cart: { added: [], failed: [] },
      verify_cart_matches!: true,
      checkout: scraper_checkout_result,
      close_order_browser!: nil
    )
  end
  let(:scraper_checkout_result) do
    { dry_run: true, total: 25.00, confirmation_number: nil, delivery_date: nil, cart_items: [] }
  end

  before do
    allow(supplier).to receive(:scraper_klass).and_return(fake_scraper_class)
    allow(fake_scraper_class).to receive(:new).with(credential).and_return(fake_scraper)
    # The service reaches the supplier through `order.supplier`, so stub on the order's instance.
    allow(order).to receive(:supplier).and_return(supplier)

    # Skip thorough pre-order validation — covered in PreOrderValidationService specs.
    allow_any_instance_of(Orders::OrderValidationService).to receive(:validate!).and_return({ warnings: [], errors: [] })
  end

  describe 'dry-run gate' do
    context 'in test environment (the default)' do
      it 'forces dry_run=true even when supplier.checkout_enabled is true' do
        supplier.update!(checkout_enabled: true)

        expect(fake_scraper).to receive(:checkout).with(dry_run: true).and_return(scraper_checkout_result)

        described_class.new(order).place_order(skip_pre_validation: true)
      end
    end

    context 'when production env is simulated' do
      before { allow(Rails.env).to receive(:production?).and_return(true) }

      it 'submits as a real order when checkout_enabled is true' do
        supplier.update!(checkout_enabled: true)
        scraper_checkout_result.merge!(dry_run: false, confirmation_number: 'CONF-XYZ')

        expect(fake_scraper).to receive(:checkout).with(dry_run: false).and_return(scraper_checkout_result)

        result = described_class.new(order).place_order(skip_pre_validation: true)

        expect(result[:success]).to be true
        expect(order.reload.status).to eq('submitted')
        expect(order.confirmation_number).to eq('CONF-XYZ')
      end

      it 'forces dry_run=true when checkout_enabled is false (per-supplier kill switch)' do
        supplier.update!(checkout_enabled: false)

        expect(fake_scraper).to receive(:checkout).with(dry_run: true).and_return(scraper_checkout_result)

        result = described_class.new(order).place_order(skip_pre_validation: true)

        expect(result[:success]).to be true
        expect(result[:dry_run]).to be true
        expect(order.reload.status).to eq('dry_run_complete')
      end
    end
  end

  describe 'order status updates' do
    it 'sets status=dry_run_complete and marks items pending on a dry run' do
      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result).to include(success: true, dry_run: true)
      expect(order.reload.status).to eq('dry_run_complete')
      expect(order.order_items.pluck(:status).uniq).to eq(['pending'])
    end

    it 'falls back to calculated_subtotal when scraper returns no total' do
      scraper_checkout_result.merge!(total: 0)

      described_class.new(order).place_order(skip_pre_validation: true)

      expect(order.reload.total_amount).to eq(20.00) # 2 * 10
    end
  end

  describe 'US Foods post-submission exception check' do
    before { allow(Rails.env).to receive(:production?).and_return(true) }

    it 'enqueues CheckOrderExceptionsJob after a live US Foods submit' do
      supplier.update!(checkout_enabled: true)
      allow(supplier).to receive(:code).and_return('usfoods')
      scraper_checkout_result.merge!(dry_run: false, confirmation_number: 'USF-1')
      allow(fake_scraper).to receive(:checkout).with(dry_run: false).and_return(scraper_checkout_result)

      expect { described_class.new(order).place_order(skip_pre_validation: true) }
        .to have_enqueued_job(CheckOrderExceptionsJob).with(order.id)
    end

    it 'does not enqueue for a non-US-Foods live submit' do
      supplier.update!(checkout_enabled: true) # code stays non-usfoods
      scraper_checkout_result.merge!(dry_run: false, confirmation_number: 'X')
      allow(fake_scraper).to receive(:checkout).and_return(scraper_checkout_result)

      expect { described_class.new(order).place_order(skip_pre_validation: true) }
        .not_to have_enqueued_job(CheckOrderExceptionsJob)
    end

    # Safety: the order is already placed before we schedule the check, so a
    # failure to enqueue must never flip a real, submitted order to failed.
    it 'keeps the order submitted even if scheduling the exception check raises' do
      supplier.update!(checkout_enabled: true)
      allow(supplier).to receive(:code).and_return('usfoods')
      scraper_checkout_result.merge!(dry_run: false, confirmation_number: 'USF-2')
      allow(fake_scraper).to receive(:checkout).with(dry_run: false).and_return(scraper_checkout_result)
      allow(CheckOrderExceptionsJob).to receive(:set).and_raise(StandardError, 'queue down')

      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result[:success]).to be true
      expect(order.reload.status).to eq('submitted')
    end
  end

  describe 'email supplier dispatch' do
    let(:supplier) { create(:supplier, :email, contact_email: 'orders@example.com') }
    let!(:credential) { nil }

    it 'routes to EmailOrderPlacementService and never instantiates a scraper' do
      email_service = instance_double(Orders::EmailOrderPlacementService, place_order: { success: true, email_sent: true })
      expect(Orders::EmailOrderPlacementService).to receive(:new).with(order).and_return(email_service)
      expect(fake_scraper_class).not_to receive(:new)

      result = described_class.new(order).place_order

      expect(result).to include(success: true, email_sent: true)
    end
  end

  describe 'missing credential' do
    it 'fails the order and raises a ValidationError when no active credential exists' do
      credential.update!(status: 'expired')

      expect {
        described_class.new(order).place_order(skip_pre_validation: true)
      }.to raise_error(Orders::OrderValidationService::ValidationError)

      expect(order.reload.status).to eq('failed')
      expect(order.error_message).to include('No active credentials')
    end
  end

  describe 'cart reconciliation gate' do
    it 'reconciles the supplier cart before checkout' do
      expect(fake_scraper).to receive(:verify_cart_matches!).with(kind_of(Array)).ordered
      expect(fake_scraper).to receive(:checkout).ordered.and_return(scraper_checkout_result)

      described_class.new(order).place_order(skip_pre_validation: true)
    end

    # Regression: an orphaned line in the supplier cart (an item the chef
    # removed) must NEVER be submitted. The order halts for review instead.
    it 'halts without checking out when the cart does not match the order' do
      allow(Rails.env).to receive(:production?).and_return(true)
      supplier.update!(checkout_enabled: true)

      mismatch = Scrapers::BaseScraper::CartMismatchError.new(
        'orphaned line',
        discrepancies: [{ type: 'extra_in_cart', sku: 'NP120', cart_qty: 1 }]
      )
      allow(fake_scraper).to receive(:verify_cart_matches!).and_raise(mismatch)
      expect(fake_scraper).not_to receive(:checkout)

      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result).to include(success: false, error_type: 'cart_mismatch', requires_review: true)
      expect(result[:details][:discrepancies]).to include(hash_including(type: 'extra_in_cart', sku: 'NP120'))
      expect(order.reload.status).to eq('pending_review')
      expect(order.confirmation_number).to be_nil
      expect(order.submitted_at).to be_nil
    end

    it 'skips the gate for scrapers that do not expose cart contents' do
      # A real object that genuinely does not respond to verify_cart_matches!
      # (unlike a loose double) — proves the respond_to? guard skips the gate so
      # suppliers without server-side carts (USF/WCW/PPO) are unaffected.
      result = scraper_checkout_result
      bare_scraper = Class.new do
        define_method(:clear_cart) {}
        define_method(:add_to_cart) { |*_args, **_kw| { added: [], failed: [] } }
        define_method(:checkout) { |**_kw| result }
        define_method(:close_order_browser!) {}
      end.new
      allow(fake_scraper_class).to receive(:new).with(credential).and_return(bare_scraper)

      expect(bare_scraper).not_to respond_to(:verify_cart_matches!)
      expect(described_class.new(order).place_order(skip_pre_validation: true)).to include(success: true)
    end
  end

  describe 'scraper exceptions' do
    it 'handles OrderMinimumError without raising' do
      err = Scrapers::BaseScraper::OrderMinimumError.new('Below minimum', minimum: 200, current_total: 20)
      allow(fake_scraper).to receive(:checkout).and_raise(err)

      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result).to include(success: false, error_type: 'order_minimum')
      expect(order.reload.status).to eq('failed')
    end

    it 'handles a generic StandardError as a failed order' do
      allow(fake_scraper).to receive(:checkout).and_raise(StandardError, 'unexpected')

      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result).to include(success: false, error_type: 'unknown')
      expect(order.reload.status).to eq('failed')
      expect(order.error_message).to include('unexpected')
    end

    it 'closes the persistent order browser even on failure (ensure block)' do
      allow(fake_scraper).to receive(:checkout).and_raise(StandardError, 'boom')

      expect(fake_scraper).to receive(:close_order_browser!)

      described_class.new(order).place_order(skip_pre_validation: true)
    end
  end
end
