require 'rails_helper'

RSpec.describe ImportSupplierProductsJob, type: :job do
  let(:supplier) { create(:supplier) }

  describe '#handle_no_credential_error' do
    # Regression — when a chef adds-and-replaces their supplier credential
    # in quick succession, the original credential.id can be deleted between
    # the time ValidateCredentialsJob enqueues an ImportSupplierProductsJob
    # and the time that job runs. find_by(id:) returns nil, the job called
    # this method, and ScrapingErrorMailer.no_credentials emailed super_admin
    # — claiming "no credentials configured for #{supplier}" even though
    # OTHER users had perfectly healthy active credentials.
    context 'when other users have active credentials for the same supplier' do
      before { create(:supplier_credential, supplier: supplier, status: 'active') }

      it 'does not send the no_credentials email' do
        job = described_class.new
        job.instance_variable_set(:@supplier, supplier)
        job.instance_variable_set(:@credential, nil)

        expect(ScrapingErrorMailer).not_to receive(:no_credentials)
        job.send(:handle_no_credential_error)
      end
    end

    context 'when no active credentials exist for the supplier' do
      it 'sends the no_credentials email' do
        job = described_class.new
        job.instance_variable_set(:@supplier, supplier)
        job.instance_variable_set(:@credential, nil)

        mailer = double('mailer', deliver_later: true)
        expect(ScrapingErrorMailer).to receive(:no_credentials).with(supplier).and_return(mailer)
        job.send(:handle_no_credential_error)
      end
    end

    context 'when only failed/expired credentials exist (no active)' do
      before do
        create(:supplier_credential, supplier: supplier, status: 'failed')
        create(:supplier_credential, :expired, supplier: supplier)
      end

      it 'still sends the no_credentials email — failed/expired are not eligible for import' do
        job = described_class.new
        job.instance_variable_set(:@supplier, supplier)
        job.instance_variable_set(:@credential, nil)

        mailer = double('mailer', deliver_later: true)
        expect(ScrapingErrorMailer).to receive(:no_credentials).with(supplier).and_return(mailer)
        job.send(:handle_no_credential_error)
      end
    end
  end

  describe '#perform — refresh_known_skus dispatch' do
    let(:credential) { create(:supplier_credential, supplier: supplier, status: 'active') }
    let(:catalog_results) { { imported: 1, updated: 2, skipped: 0, errors: [] } }
    let(:service) { instance_double(ImportSupplierProductsService) }

    before do
      allow(ImportSupplierProductsService).to receive(:new).with(credential).and_return(service)
      allow(service).to receive(:import_catalog).and_return(catalog_results)
      allow(service).to receive(:release_import_indexes!)
    end

    context 'when the supplier scraper implements refresh_known_skus' do
      let(:scraper) { instance_double(Scrapers::UsFoodsScraper) }

      before do
        supplier.update!(scraper_class: 'Scrapers::UsFoodsScraper')
        allow(Scrapers::UsFoodsScraper).to receive(:new).with(credential).and_return(scraper)
        allow(scraper).to receive(:respond_to?).with(:refresh_known_skus).and_return(true)
      end

      it 'calls refresh_known_products after the catalog import' do
        expect(service).to receive(:refresh_known_products).with(scraper: scraper)
          .and_return(updated: 7, missed: 2, batches: 3)

        described_class.new.perform(supplier.id, credential.id)
      end

      it 'passes the same scraper instance to both import_catalog and refresh_known_products' do
        expect(service).to receive(:import_catalog).with(search_terms: nil, scraper: scraper).and_return(catalog_results)
        expect(service).to receive(:refresh_known_products).with(scraper: scraper)
          .and_return(updated: 0, missed: 0, batches: 0)

        described_class.new.perform(supplier.id, credential.id)
      end

      # Regression — a failure inside refresh_known_products must not invalidate
      # the catalog import that already succeeded. Mirrors the isolated rescue
      # around refresh in SyscoCombinedImportJob.
      it 'does not let a refresh failure mark a successful catalog import as failed' do
        allow(service).to receive(:refresh_known_products).and_raise(StandardError, 'API timeout')

        expect(ScrapingErrorMailer).not_to receive(:import_failed)
        expect { described_class.new.perform(supplier.id, credential.id) }.not_to raise_error
      end
    end

    context 'when the supplier scraper does not implement refresh_known_skus' do
      # BaseScraper has no refresh_known_skus method, so respond_to? naturally returns false.
      let(:scraper) { instance_double(Scrapers::BaseScraper) }

      before do
        # Default supplier factory uses Scrapers::BaseScraper
        allow(Scrapers::BaseScraper).to receive(:new).with(credential).and_return(scraper)
      end

      it 'does not call refresh_known_products' do
        expect(service).not_to receive(:refresh_known_products)

        described_class.new.perform(supplier.id, credential.id)
      end
    end
  end
end
