require 'rails_helper'

RSpec.describe DeepCatalogImportJob, type: :job do
  let(:supplier) { create(:supplier, scraper_class: 'Scrapers::WhatChefsWantScraper') }

  describe '#find_credential' do
    # Regression: the job used to require a super_admin credential, but none
    # exist in production — so every deep import silently skipped. It must fall
    # back to any active credential.
    it 'falls back to an active credential when no super_admin credential exists' do
      user = create(:user)
      cred = create(:supplier_credential, supplier: supplier, user: user, status: 'active')

      expect(described_class.new.send(:find_credential, supplier)).to eq(cred)
    end

    it 'returns nil when there is no usable credential' do
      expect(described_class.new.send(:find_credential, supplier)).to be_nil
    end

    it 'ignores non-active credentials in the fallback' do
      user = create(:user)
      create(:supplier_credential, supplier: supplier, user: user, status: 'expired')

      expect(described_class.new.send(:find_credential, supplier)).to be_nil
    end
  end
end
