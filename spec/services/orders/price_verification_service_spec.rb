require 'rails_helper'

RSpec.describe Orders::PriceVerificationService, type: :service do
  let(:user) { create(:user, :with_organization) }
  let(:supplier) { create(:supplier) }
  let(:supplier_product) { create(:supplier_product, supplier: supplier, current_price: 10.00) }
  let(:order) do
    create(:order,
           user: user,
           supplier: supplier,
           organization: user.current_organization,
           subtotal: 20.00,
           total_amount: 20.00).tap do |o|
      create(:order_item, order: o, supplier_product: supplier_product, quantity: 2, unit_price: 10.00)
    end
  end

  let(:fake_scraper_class) { double('FakeScraperClass') }
  let(:fake_scraper) do
    instance_double(
      'FakeScraper',
      scrape_prices: [],
      last_delivery_address: nil,
      soft_refresh: true
    )
  end

  before do
    allow(supplier).to receive(:scraper_klass).and_return(fake_scraper_class)
    allow(fake_scraper_class).to receive(:new).and_return(fake_scraper)
    allow(order).to receive(:supplier).and_return(supplier)
  end

  describe 'fast path: fresh prices' do
    before do
      supplier_product.update!(price_updated_at: 5.minutes.ago)
    end

    it 'skips live verification and uses cached prices' do
      expect(fake_scraper_class).not_to receive(:new)

      result = described_class.new(order).verify!

      expect(result).to include(success: true, has_price_changes: false, verification_status: 'verified')
      expect(order.reload.verification_status).to eq('verified')
      expect(order.order_items.first.reload.verified_price).to eq(10.00)
    end

    # Gap 2 (Oct 19 2026): for a supplier whose price check reads live stock,
    # that read is the last stock check before Place, so fresh prices don't
    # skip it.
    it 'still reads live when the price check is also the stock check' do
      allow(fake_scraper_class).to receive(:reports_live_stock?).and_return(true)
      create(:supplier_credential, user: user, supplier: supplier, status: 'active')
      allow(fake_scraper).to receive(:scrape_prices).and_return(
        [{ supplier_sku: supplier_product.supplier_sku, current_price: 10.00, in_stock: false, stock_signal: '0.0', supplier_name: 'Foo' }]
      )

      described_class.new(order).verify!

      expect(fake_scraper).to have_received(:scrape_prices)
      expect(supplier_product.reload.in_stock).to be(false)
    end
  end

  describe 'no credential' do
    before { supplier_product.update!(price_updated_at: 2.hours.ago) }

    context 'on a password-required supplier' do
      it 'fails verification' do
        result = described_class.new(order).verify!

        expect(result).to include(success: false, verification_status: 'failed')
        expect(result[:error]).to include('No saved login')
        expect(order.reload.verification_status).to eq('failed')
      end
    end

    context 'on a 2FA-only supplier' do
      let(:supplier) { create(:supplier, :two_fa) }

      it 'skips verification gracefully (cannot auto-relogin)' do
        result = described_class.new(order).verify!

        expect(result).to include(success: true, skipped: true, verification_status: 'skipped')
        expect(order.reload.verification_status).to eq('skipped')
      end
    end
  end

  describe 'with active credential' do
    let!(:credential) { create(:supplier_credential, user: user, supplier: supplier, status: 'active') }
    before { supplier_product.update!(price_updated_at: 2.hours.ago) }

    context 'when prices match' do
      it 'marks the order verified with no price changes' do
        allow(fake_scraper).to receive(:scrape_prices).and_return([
          { supplier_sku: supplier_product.supplier_sku, current_price: 10.00, in_stock: true, supplier_name: 'Foo' }
        ])

        result = described_class.new(order).verify!

        expect(result).to include(success: true, has_price_changes: false, verification_status: 'verified')
        expect(order.reload.verification_status).to eq('verified')
      end
    end

    context 'when prices changed beyond the 5% threshold' do
      it 'marks the order price_changed' do
        allow(fake_scraper).to receive(:scrape_prices).and_return([
          { supplier_sku: supplier_product.supplier_sku, current_price: 15.00, in_stock: true, supplier_name: 'Foo' }
        ])

        result = described_class.new(order).verify!

        expect(result[:has_price_changes]).to be true
        expect(order.reload.verification_status).to eq('price_changed')
        expect(order.reload.status).to eq('price_changed')
      end
    end

    context 'when prices changed within threshold' do
      it 'marks the order verified (within 5% is auto-accepted)' do
        # Order subtotal = 20. 5% = 1.00. Verified price 10.40 → +0.80 total change.
        allow(fake_scraper).to receive(:scrape_prices).and_return([
          { supplier_sku: supplier_product.supplier_sku, current_price: 10.40, in_stock: true, supplier_name: 'Foo' }
        ])

        described_class.new(order).verify!

        expect(order.reload.verification_status).to eq('verified')
      end
    end

    # Regression: order #145 — catch-weight pork verified per-LB ($2.00) against
    # a case-priced line (~$100), reported a phantom price drop, and accepting
    # it wrote the per-pound price into the submitted order.
    context 'catch-weight (per-LB) items' do
      let(:supplier_product) do
        create(:supplier_product, supplier: supplier, current_price: 2.00,
               price_unit: 'LB', pack_size: '4/10 LB', price_updated_at: 2.hours.ago)
      end
      let(:order) do
        create(:order,
               user: user,
               supplier: supplier,
               organization: user.current_organization,
               subtotal: 240.00,
               total_amount: 240.00).tap do |o|
          create(:order_item, order: o, supplier_product: supplier_product, quantity: 3, unit_price: 80.00, uom: 'CS')
        end
      end

      it 'converts the per-LB verified price to the case equivalent (no phantom change)' do
        allow(fake_scraper).to receive(:scrape_prices).and_return([
          { supplier_sku: supplier_product.supplier_sku, current_price: 2.00, price_unit: 'LB', in_stock: true, supplier_name: 'Pork' }
        ])

        result = described_class.new(order).verify!

        expect(result[:has_price_changes]).to be false
        expect(order.order_items.first.reload.verified_price).to eq(80.00)
        expect(order.reload.verification_status).to eq('verified')
      end

      it 'stores the RAW per-LB price in the supplier_product cache on a real change' do
        allow(fake_scraper).to receive(:scrape_prices).and_return([
          { supplier_sku: supplier_product.supplier_sku, current_price: 2.10, price_unit: 'LB', in_stock: true, supplier_name: 'Pork' }
        ])

        described_class.new(order).verify!

        expect(order.order_items.first.reload.verified_price).to eq(84.00)
        expect(supplier_product.reload.current_price).to eq(2.10)
      end

      it 'treats an implausible verified price as unverified instead of offering it' do
        # Simulate a scraper that fails to report the unit AND a product with no
        # stored price_unit — the raw $2.00 would face the $80.00 line directly.
        supplier_product.update!(price_unit: nil)
        allow(fake_scraper).to receive(:scrape_prices).and_return([
          { supplier_sku: supplier_product.supplier_sku, current_price: 2.00, in_stock: true, supplier_name: 'Pork' }
        ])

        result = described_class.new(order).verify!

        expect(result[:has_price_changes]).to be false
        expect(order.reload.verification_status).to eq('verified')
        # Line keeps its imported price — nothing offers the chef a $2.00 case
        item = order.order_items.first.reload
        expect(item.verified_price).to eq(80.00)
        expect(item.unit_price).to eq(80.00)
        expect(result[:results].first[:unverified]).to be true
        expect(result[:results].first[:implausible]).to be true
      end
    end

    context 'when scraper raises CaptchaDetectedError' do
      it 'skips verification rather than failing' do
        allow(fake_scraper).to receive(:scrape_prices).and_raise(Scrapers::BaseScraper::CaptchaDetectedError, 'captcha')

        result = described_class.new(order).verify!

        expect(result).to include(success: true, skipped: true)
        expect(order.reload.verification_status).to eq('skipped')
      end
    end

    context 'when scraper raises RateLimitedError' do
      it 'fails verification' do
        allow(fake_scraper).to receive(:scrape_prices).and_raise(Scrapers::BaseScraper::RateLimitedError, 'busy')

        result = described_class.new(order).verify!

        expect(result).to include(success: false, verification_status: 'failed')
        expect(order.reload.verification_status).to eq('failed')
      end
    end

    context 'when scraper raises an unexpected error' do
      it 'fails verification with a generic message' do
        allow(fake_scraper).to receive(:scrape_prices).and_raise(StandardError, 'kaboom')

        result = described_class.new(order).verify!

        expect(result).to include(success: false, verification_status: 'failed')
        expect(order.reload.verification_status).to eq('failed')
      end
    end
  end

  # Carmin, Oct 19 2026 (D1): an item that went out between the morning run
  # and order time is shown at the price check so the chef can remove it.
  # Only scrapers that read live stock (US Foods) may change the flag; the
  # rest return a placeholder in_stock: true that must never clear an "out".
  describe 'live stock at the price check' do
    let!(:credential) { create(:supplier_credential, user: user, supplier: supplier, status: 'active') }
    before { supplier_product.update!(price_updated_at: 2.hours.ago) }

    def scrape(in_stock, signal: nil)
      allow(fake_scraper).to receive(:scrape_prices).and_return([
        { supplier_sku: supplier_product.supplier_sku, current_price: 10.00, in_stock: in_stock,
          stock_signal: signal, supplier_name: 'Foo' }
      ])
    end

    context 'for a scraper that reports live stock' do
      before { allow(fake_scraper_class).to receive(:reports_live_stock?).and_return(true) }

      it 'marks the item out even when the price did not change' do
        scrape(false)

        described_class.new(order).verify!

        expect(supplier_product.reload.in_stock).to be(false)
      end

      it 'marks it back in when the supplier has it again' do
        supplier_product.update!(in_stock: false)
        scrape(true)

        described_class.new(order).verify!

        expect(supplier_product.reload.in_stock).to be(true)
      end

      it 'changes nothing when the supplier did not say (nil)' do
        supplier_product.update!(in_stock: false)
        scrape(nil)

        described_class.new(order).verify!

        expect(supplier_product.reload).to have_attributes(in_stock: false, stock_checked_at: nil)
      end

      # Plan 3.3: the reading is recorded even when the flag didn't change,
      # so a fresh "out" can be told from a stale one.
      it 'records the reading as evidence, even when nothing changed' do
        scrape(true, signal: '12.0')

        described_class.new(order).verify!

        expect(supplier_product.reload).to have_attributes(in_stock: true, stock_signal: '12.0', stock_source: 'price_check')
        expect(supplier_product.stock_checked_at).to be_within(1.minute).of(Time.current)
      end

      it 'keeps a live "out" when the price also changed' do
        allow(fake_scraper).to receive(:scrape_prices).and_return([
          { supplier_sku: supplier_product.supplier_sku, current_price: 10.30, in_stock: false, supplier_name: 'Foo' }
        ])

        described_class.new(order).verify!

        expect(supplier_product.reload).to have_attributes(in_stock: false, current_price: 10.30)
      end
    end

    it 'never lets a placeholder "in stock" clear a real out for other scrapers' do
      supplier_product.update!(in_stock: false)
      scrape(true)

      described_class.new(order).verify!

      expect(supplier_product.reload.in_stock).to be(false)
    end
  end

  describe 'auth error fallback for password suppliers' do
    let!(:credential) { create(:supplier_credential, user: user, supplier: supplier, status: 'active') }

    before { supplier_product.update!(price_updated_at: 2.hours.ago) }

    it 'skips when prices were updated within 24 hours' do
      supplier_product.update!(price_updated_at: 6.hours.ago)
      allow(fake_scraper).to receive(:scrape_prices).and_raise(Scrapers::BaseScraper::AuthenticationError, 'bad creds')

      result = described_class.new(order).verify!

      expect(result).to include(success: true, skipped: true)
      expect(order.reload.verification_status).to eq('skipped')
    end

    it 'fails when prices are stale (older than 24 hours)' do
      supplier_product.update!(price_updated_at: 2.days.ago)
      allow(fake_scraper).to receive(:scrape_prices).and_raise(Scrapers::BaseScraper::AuthenticationError, 'bad creds')

      result = described_class.new(order).verify!

      expect(result).to include(success: false, verification_status: 'failed')
      expect(order.reload.verification_status).to eq('failed')
    end
  end
end
