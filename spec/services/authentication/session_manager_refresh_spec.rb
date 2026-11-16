require 'rails_helper'

# The scheduled refresh (RefreshSessionJob → SessionManager#refresh_session).
# Oct 21 2026: Performance logins end 24 hours after a real sign-in. The API
# refresh kept "succeeding" right up to the end, then handed back a refresh
# token good for 6 seconds, and the login stayed dead until the next
# scheduled refresh 6–8 hours later. Now a refresh that says the login ends
# soon signs in again with the stored password.
RSpec.describe Authentication::SessionManager do
  let(:supplier) { create(:supplier) } # password auth
  let(:credential) { create(:supplier_credential, supplier: supplier, status: 'active') }
  let(:manager) { described_class.new(credential) }
  let(:scraper) { instance_double(Scrapers::PerformanceScraper) }

  before do
    allow_any_instance_of(Supplier).to receive(:scraper_klass).and_return(double(new: scraper))
  end

  describe '#refresh_session' do
    context 'when the refresh works and the login has plenty left' do
      it 'is done, with no new sign-in' do
        allow(scraper).to receive_messages(soft_refresh: true, login_ending_soon?: false)
        expect(scraper).not_to receive(:renew_login)

        expect(manager.refresh_session).to be(true)
      end
    end

    context 'when the refresh works but the login ends soon' do
      before { allow(scraper).to receive_messages(soft_refresh: true, login_ending_soon?: true) }

      it 'signs in again with the stored password' do
        expect(scraper).to receive(:renew_login).and_return(true)

        expect(manager.refresh_session).to be(true)
      end

      it 'still reports the refresh as working when signing in again fails (the session is kept)' do
        expect(scraper).to receive(:renew_login).and_return(false)

        expect(manager.refresh_session).to be(true)
        expect(credential.reload.status).to eq('active')
      end
    end

    context 'for suppliers that cannot tell when a login ends (every other supplier)' do
      let(:scraper) { instance_double(Scrapers::ChefsWarehouseScraper) }

      it 'behaves exactly as before' do
        allow(scraper).to receive(:soft_refresh).and_return(true)

        expect(manager.refresh_session).to be(true)
      end
    end

    context 'when the refresh fails' do
      it 'still falls through to a full password login, as before' do
        allow(scraper).to receive(:soft_refresh).and_return(false)
        expect(scraper).not_to receive(:renew_login)
        expect(scraper).to receive(:login)

        expect(manager.refresh_session).to be(true)
      end
    end
  end
end
