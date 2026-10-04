require 'rails_helper'

# Which suppliers confirm every line is on their cart before submitting —
# the gate for letting the supplier (not our cache) decide stock.
RSpec.describe 'Scrapers#confirms_lines_before_submit?' do
  let(:credential) { build_stubbed(:supplier_credential) }

  {
    Scrapers::ChefsWarehouseScraper => true,
    Scrapers::WhatChefsWantScraper => true,
    Scrapers::PerformanceScraper => true,
    Scrapers::SyscoScraper => true,
    Scrapers::UsFoodsScraper => false,
    Scrapers::PremiereProduceOneScraper => false
  }.each do |klass, expected|
    it "#{klass.name.demodulize}: #{expected}" do
      expect(klass.new(credential).confirms_lines_before_submit?).to be(expected)
    end
  end
end
