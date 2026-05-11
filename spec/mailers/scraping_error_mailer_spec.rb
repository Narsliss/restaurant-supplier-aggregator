require 'rails_helper'

RSpec.describe ScrapingErrorMailer, type: :mailer do
  let(:supplier) { create(:supplier, name: 'Acme Foods') }
  let!(:super_admin) { create(:user, :super_admin) }

  # Regression: ScrapingErrorMailer#no_credentials used to reference
  # Rails.application.routes.url_helpers.suppliers_url, which doesn't exist
  # (there is no `:suppliers` resource — only :supplier_credentials and
  # :email_suppliers). The mailer crashed with NoMethodError before reaching
  # the mail() call, so every alert from ImportSupplierProductsJob died.
  describe '#no_credentials' do
    it 'renders the alert without raising on missing route helpers' do
      mail = described_class.no_credentials(supplier)
      expect { mail.body }.not_to raise_error
      expect(mail.subject).to include('Missing Credentials')
      expect(mail.subject).to include('Acme Foods')
      expect(mail.to).to eq([super_admin.email])
    end

    it 'returns a no-op when no super_admin exists' do
      super_admin.destroy!
      mail = described_class.no_credentials(supplier)
      expect(mail.to).to be_nil
    end
  end

  describe '#credentials_expired' do
    let(:credential) { create(:supplier_credential, supplier: supplier) }

    it 'renders the alert without raising on missing route helpers' do
      mail = described_class.credentials_expired(supplier, credential)
      expect { mail.body }.not_to raise_error
      expect(mail.subject).to include('Credentials Expired')
      expect(mail.to).to eq([super_admin.email])
    end
  end
end
