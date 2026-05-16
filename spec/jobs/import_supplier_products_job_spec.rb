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
end
