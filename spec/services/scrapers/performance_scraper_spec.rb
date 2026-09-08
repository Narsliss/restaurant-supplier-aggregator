require 'rails_helper'

RSpec.describe Scrapers::PerformanceScraper do
  let(:supplier) { create(:supplier) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:scraper) { described_class.new(credential) }

  # Catalog/lists/prices are later phases. Until then these must no-op WITHOUT
  # opening a browser — a freshly validated credential kicks off
  # ImportSupplierProductsJob + ImportSupplierListsJob immediately, and a
  # raise here would flip the brand-new credential to failed.
  describe 'not-yet-implemented phases' do
    it 'returns [] from scrape_catalog without opening a browser' do
      expect(scraper).not_to receive(:with_browser)
      expect(scraper.scrape_catalog(%w[chicken])).to eq([])
    end

    it 'returns [] from scrape_lists without opening a browser' do
      expect(scraper).not_to receive(:with_browser)
      expect(scraper.scrape_lists).to eq([])
    end

    it 'returns [] from scrape_prices without opening a browser' do
      expect(scraper).not_to receive(:with_browser)
      expect(scraper.scrape_prices(%w[12345])).to eq([])
    end
  end

  describe '#logged_in?' do
    let(:browser) { instance_double(Ferrum::Browser) }

    before { allow(scraper).to receive(:browser).and_return(browser) }

    it 'is false while still parked on the B2C identity host' do
      allow(browser).to receive(:current_url)
        .and_return('https://pfgcustomerfirst.b2clogin.com/pfgcustomerfirst.onmicrosoft.com/B2C_1A_signup_signin/')

      expect(scraper.logged_in?).to be(false)
    end

    it 'is true on the app origin once MSAL has cached tokens' do
      allow(browser).to receive(:current_url).and_return('https://www.customerfirstsolutions.com/home')
      allow(browser).to receive(:evaluate).and_return(true)

      expect(scraper.logged_in?).to be(true)
    end

    it 'is false on the app origin when storage has no MSAL entries (login bounced)' do
      allow(browser).to receive(:current_url).and_return('https://www.customerfirstsolutions.com/')
      allow(browser).to receive(:evaluate).and_return(false)

      expect(scraper.logged_in?).to be(false)
    end
  end

  describe 'supplier seeding' do
    it 'registers the performance supplier with password auth' do
      seed = Rails.root.join('config/initializers/seed_suppliers.rb').read
      expect(seed).to include("code: 'performance'")
      expect(seed).to include("scraper_class: 'Scrapers::PerformanceScraper'")
      expect(seed).to match(/code: 'performance',.*?auth_type: 'password'/m)
    end
  end
end
