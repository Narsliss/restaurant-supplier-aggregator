require 'rails_helper'

RSpec.describe Supplier, type: :model do
  describe 'validations' do
    it 'requires base_url, login_url, scraper_class for non-email suppliers' do
      s = build(:supplier, base_url: nil, login_url: nil, scraper_class: nil)
      expect(s).not_to be_valid
      expect(s.errors[:base_url]).to be_present
      expect(s.errors[:login_url]).to be_present
      expect(s.errors[:scraper_class]).to be_present
    end

    it 'requires contact_email for email suppliers and skips web fields' do
      s = build(:supplier, :email)
      expect(s).to be_valid
    end

    it 'requires contact_email when auth_type is email' do
      s = build(:supplier, :email, contact_email: nil)
      expect(s).not_to be_valid
      expect(s.errors[:contact_email]).to be_present
    end

    it 'enforces auth_type inclusion' do
      s = build(:supplier, auth_type: 'wat')
      expect(s).not_to be_valid
    end

    it 'enforces unique code' do
      existing = create(:supplier, code: 'unique-test-code-1')
      duplicate = build(:supplier, code: existing.code)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:code]).to be_present
    end
  end

  describe 'auth_type predicates' do
    it { expect(build(:supplier, auth_type: 'password').password_auth?).to be true }
    it { expect(build(:supplier, :two_fa).two_fa_only?).to be true }
    it { expect(build(:supplier, auth_type: 'welcome_url').welcome_url_auth?).to be true }
    it { expect(build(:supplier, :email).email_supplier?).to be true }

    it '#no_password_required? is true for any non-password auth' do
      expect(build(:supplier, :two_fa).no_password_required?).to be true
      expect(build(:supplier, auth_type: 'welcome_url').no_password_required?).to be true
      expect(build(:supplier, :email).no_password_required?).to be true
      expect(build(:supplier).no_password_required?).to be false
    end
  end

  describe '#checkout_enabled?' do
    it 'reflects the boolean column' do
      expect(build(:supplier, checkout_enabled: true).checkout_enabled?).to be true
      expect(build(:supplier, checkout_enabled: false).checkout_enabled?).to be false
    end
  end

  describe '#scraper_klass' do
    it 'constantizes scraper_class' do
      supplier = build(:supplier, scraper_class: 'Scrapers::BaseScraper')
      expect(supplier.scraper_klass).to eq(Scrapers::BaseScraper)
    end
  end

  describe '#api_delivery_dates?' do
    it 'is true only for sysco' do
      expect(build(:supplier, code: 'sysco').api_delivery_dates?).to be true
      expect(build(:supplier, code: 'usfoods').api_delivery_dates?).to be false
    end
  end

  describe 'display helpers' do
    it '#short_name returns the canonical short label for known codes' do
      expect(build(:supplier, code: 'usfoods').short_name).to eq('US Foods')
      expect(build(:supplier, code: 'whatchefswant').short_name).to eq('WCW')
      expect(build(:supplier, code: 'chefswarehouse').short_name).to eq("Chef's WH")
      expect(build(:supplier, code: 'premiereproduceone').short_name).to eq('PPO')
    end

    it '#short_name truncates the name for unknown codes' do
      expect(build(:supplier, code: 'unknown', name: 'A Very Long Supplier Name').short_name)
        .to eq('A Very Long...')
    end

    it '#brand_color_class returns the brand color or fallback' do
      expect(build(:supplier, code: 'usfoods').brand_color_class).to eq('text-red-600')
      expect(build(:supplier, code: 'unknown').brand_color_class).to eq('text-gray-400')
    end
  end

  describe 'scopes' do
    let!(:active_supplier) { create(:supplier, active: true) }
    let!(:inactive_supplier) { create(:supplier, active: false) }
    let!(:two_fa) { create(:supplier, :two_fa) }
    let!(:email) { create(:supplier, :email) }

    it '.active filters by active=true' do
      expect(Supplier.active).to include(active_supplier, two_fa, email)
      expect(Supplier.active).not_to include(inactive_supplier)
    end

    it '.password_required excludes 2FA-only suppliers' do
      expect(Supplier.password_required).to include(active_supplier, inactive_supplier)
      expect(Supplier.password_required).not_to include(two_fa)
    end

    it '.email_suppliers returns only auth_type=email' do
      expect(Supplier.email_suppliers).to contain_exactly(email)
    end

    it '.web_suppliers excludes email auth_type' do
      expect(Supplier.web_suppliers).not_to include(email)
    end
  end
end
