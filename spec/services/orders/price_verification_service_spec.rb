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
