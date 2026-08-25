require 'rails_helper'

RSpec.describe Scrapers::SyscoScraper do
  # build_pack_size is pure (depends only on its argument), so we exercise it
  # via .allocate to avoid constructing a real credential / browser session.
  subject(:scraper) { described_class.allocate }

  describe '#build_pack_size' do
    def build(pack, size)
      scraper.send(:build_pack_size, { 'pack' => pack, 'size' => size })
    end

    it 'joins case count and per-unit size with an explicit "x" multiplier' do
      expect(build('12', '12 OZ')).to eq('12x12 OZ')
      expect(build('4', '3 LB')).to eq('4x3 LB')
      expect(build('6', '6 LB')).to eq('6x6 LB')
    end

    # Regression: "12 12 OZ" (12 bottles x 12 oz = 144 oz) was mis-parsed as a
    # single 12 oz unit, inflating per-unit price ~12x. The "x" form must parse
    # to the full case quantity.
    it 'produces a string UnitParser reads as the full case quantity (count == size)' do
      packed = build('12', '12 OZ')
      parsed = UnitParser.parse(packed)
      expect(parsed[:normalized_quantity]).to eq(144.0)
      expect(parsed[:normalized_unit]).to eq('oz')
      # $91.85 case → $0.64/oz, not $7.65/oz
      expect(UnitParser.per_unit_price(91.85, packed)).to eq(0.6378)
    end

    it 'does not regress non-equal case packs' do
      expect(UnitParser.parse(build('4', '3 LB'))[:normalized_quantity]).to eq(192.0)
    end

    it 'leaves catch-weight sizes (no count number) as a plain space join' do
      # size has no leading digit → must not become "40xLB"
      expect(build('40', 'LB')).to eq('40 LB')
    end

    it 'handles a missing pack count' do
      expect(build(nil, '12 OZ')).to eq('12 OZ')
      expect(build('', '12 OZ')).to eq('12 OZ')
    end

    it 'strips a duplicated trailing unit' do
      expect(build('4', '3 LB LB')).to eq('4x3 LB')
    end

    it 'returns nil for blank input' do
      expect(build(nil, nil)).to be_nil
      expect(build('', '')).to be_nil
    end
  end

  # Regression for the Sysco→Okta login migration (broke ~June 2026): the first
  # login now lands on the Okta "My Apps" dashboard (secure.sysco.com/app/UserHome),
  # not the shop. The scraper must then hop to the shop login, which SSOs through
  # the established Okta session — no password is asked the second time.
  describe '#perform_login_steps (Okta → shop handoff)' do
    let(:browser) { instance_double('Ferrum::Browser') }

    before do
      # Neutralize everything that touches a real browser/session/clock so we can
      # exercise just the stage routing logic.
      allow(scraper).to receive(:logger).and_return(Logger.new(File::NULL))
      allow(scraper).to receive(:sleep)
      allow(scraper).to receive(:browser).and_return(browser)
      allow(scraper).to receive(:navigate_to)
      allow(scraper).to receive(:apply_stealth)
      allow(scraper).to receive(:fill_login_email).and_return(true)
      allow(scraper).to receive(:click_next_button)
      allow(scraper).to receive(:fill_login_password).and_return(true)
      allow(scraper).to receive(:check_remember_me)
      allow(scraper).to receive(:click_login_submit)
      allow(scraper).to receive(:handle_mfa_if_prompted).and_return(false)
      allow(scraper).to receive(:detect_login_errors)
      allow(scraper).to receive(:log_page_state)
      allow(scraper).to receive(:dismiss_promo_modals)
      allow(scraper).to receive(:diagnose_login_failure)
      allow(scraper).to receive(:credential).and_return(double(username: 'chef@example.com'))
    end

    it 'navigates to the shop login when stranded on the Okta dashboard, then succeeds via SSO' do
      # current_url reads: (1) right after first nav, (2) after first submit = Okta
      # dashboard, (3) after the shop-login navigation = shop auth page.
      allow(browser).to receive(:current_url).and_return(
        'https://secure.sysco.com/',
        'https://secure.sysco.com/app/UserHome?iss=...&session_hint=AUTHENTICATED',
        'https://shop.sysco.com/auth/login'
      )
      # Not logged in after stage 1 or on landing the shop page; logged in once the
      # shop SSOs the email through (no password prompt).
      allow(scraper).to receive(:logged_in?).and_return(false, false, true)

      expect { scraper.send(:perform_login_steps) }.not_to raise_error
      expect(scraper).to have_received(:navigate_to).with(described_class::SHOP_LOGIN_URL)
      # SSO path must not fall back to entering a shop password — only the first
      # (Okta) stage submits a form.
      expect(scraper).to have_received(:click_login_submit).once
    end

    it 'still raises when the shop never authenticates (no silent failure)' do
      allow(browser).to receive(:current_url).and_return(
        'https://secure.sysco.com/',
        'https://secure.sysco.com/app/UserHome?session_hint=AUTHENTICATED',
        'https://shop.sysco.com/auth/login'
      )
      allow(scraper).to receive(:logged_in?).and_return(false)

      expect { scraper.send(:perform_login_steps) }
        .to raise_error(Scrapers::BaseScraper::AuthenticationError, /not authenticated/)
      expect(scraper).to have_received(:navigate_to).with(described_class::SHOP_LOGIN_URL)
    end
  end

  describe '#price_unit_for' do
    def node(catch_weight:, case_price: nil, each_price: nil)
      {
        'productInfo' => { 'isCatchWeight' => catch_weight },
        'priceInfoV2' => {
          'case' => case_price ? { 'netPrice' => case_price } : {},
          'each' => each_price ? { 'netPrice' => each_price } : {}
        }
      }
    end

    def unit_for(pp)
      scraper.send(:price_unit_for, pp, pp.dig('priceInfoV2', 'case') || {}, pp.dig('priceInfoV2', 'each') || {})
    end

    # Regression: Sysco bills catch-weight items (meat, whole cheeses) at a
    # per-POUND rate in priceInfoV2.case.netPrice. Stamping those 'CS' made a
    # 24 lb case of smoked gouda read as $5.12 for the case, so Sysco undercut
    # every competitor by the pack weight and the savings reports showed
    # impossible numbers. The API tells us via productInfo.isCatchWeight.
    it 'labels a catch-weight case price per pound' do
      expect(unit_for(node(catch_weight: true, case_price: 5.46))).to eq('LB')
    end

    it 'labels an ordinary case price as a case' do
      expect(unit_for(node(catch_weight: false, case_price: 43.45))).to eq('CS')
    end

    it 'treats a missing isCatchWeight flag as an ordinary case' do
      pp = { 'priceInfoV2' => { 'case' => { 'netPrice' => 43.45 }, 'each' => {} } }
      expect(unit_for(pp)).to eq('CS')
    end

    it 'labels an each-only price as EA regardless of catch weight' do
      expect(unit_for(node(catch_weight: true, each_price: 3.99))).to eq('EA')
    end

    it 'returns nil when there is no price at all' do
      expect(unit_for(node(catch_weight: true))).to be_nil
    end
  end

  describe 'catch-weight pricing end to end' do
    # A per-pound quote must survive into a comparable per-oz rate rather than
    # being spread across the whole case.
    it 'yields a per-oz rate from the pound rate, not the case' do
      sp = SupplierProduct.new(current_price: 5.46, price_unit: 'LB', pack_size: '4x6 LB')
      expect(sp.per_unit_price.to_f).to be_within(0.001).of(0.34125)
      expect(sp.estimated_case_price.to_f).to be_within(0.01).of(131.04)
    end

    it 'reads an ordinary case price across the pack' do
      sp = SupplierProduct.new(current_price: 43.45, price_unit: 'CS', pack_size: '4x5 LB')
      expect(sp.per_unit_price.to_f).to be_within(0.001).of(0.1358)
      expect(sp.estimated_case_price.to_f).to eq(43.45)
    end
  end
end
