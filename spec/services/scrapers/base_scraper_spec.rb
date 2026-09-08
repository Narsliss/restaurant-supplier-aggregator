require 'rails_helper'

RSpec.describe Scrapers::BaseScraper do
  let(:supplier) { create(:supplier) }
  let(:credential) { create(:supplier_credential, supplier: supplier) }
  let(:scraper) { described_class.new(credential) }
  let(:browser) { instance_double(Ferrum::Browser) }

  before { allow(scraper).to receive(:browser).and_return(browser) }

  describe '#detect_maintenance' do
    # Regression: browser.body returns the raw HTML String in Ferrum, which has
    # no #text — every scraper that called detect_error_conditions crashed with
    # "undefined method `text' for an instance of String" before reaching the
    # login form (first observed validating the Performance credential).
    it 'reads rendered page text without calling #text on the HTML string' do
      allow(browser).to receive(:evaluate)
        .with(a_string_including('innerText')).and_return('Please sign in.')

      expect { scraper.send(:detect_maintenance) }.not_to raise_error
    end

    it 'raises MaintenanceError when the visible text announces downtime' do
      allow(browser).to receive(:evaluate)
        .with(a_string_including('innerText')).and_return('We are down for scheduled downtime')

      expect { scraper.send(:detect_maintenance) }
        .to raise_error(described_class::MaintenanceError)
    end

    it 'treats an evaluation failure as no maintenance rather than crashing the login' do
      allow(browser).to receive(:evaluate).and_raise(Ferrum::BrowserError.new({ 'message' => 'boom' }))

      expect { scraper.send(:detect_maintenance) }.not_to raise_error
    end
  end
end
