require 'rails_helper'

RSpec.describe Scrapers::SyscoScraper do
  # build_pack_size is pure (depends only on its argument), so we exercise it
  # via .allocate to avoid constructing a real credential / browser session.
  subject(:scraper) { described_class.allocate }

  describe '#build_pack_size' do
    def build(pack, size)
      scraper.send(:build_pack_size, { 'pack' => pack, 'size' => size })
    end

    # Regression: Sysco splits some sizes into a bare number plus a separate
    # `uom` ("11.5" + "OZ"). Discarding uom produced "12x11.5", which UnitParser
    # cannot read at all, so the item never earned a per-unit price and sat out
    # every comparison.
    context 'when the size carries no unit of its own' do
      def build_with_uom(pack, size, uom)
        scraper.send(:build_pack_size, { 'pack' => pack, 'size' => size, 'uom' => uom })
      end

      it 'reattaches uom so the pack string parses' do
        packed = build_with_uom('12', '11.5', 'OZ')
        expect(packed).to eq('12x11.5 OZ')
        expect(UnitParser.parse(packed)[:normalized_quantity]).to eq(138.0)
      end

      it 'leaves a size that already names its own unit untouched' do
        expect(build_with_uom('12', '12 OZ', 'OZ')).to eq('12x12 OZ')
      end

      # Sysco sends grams as uom "G" (and gallons as "GAL"); a bare "G" reads
      # as gallons to UnitParser, which made a 64x140 G case of truffle honey
      # 1.1 million fl oz and its per-unit price effectively zero.
      it 'spells Sysco grams out so they are not read as gallons' do
        packed = build_with_uom('64', '140', 'G')
        expect(packed).to eq('64x140 GR')
        expect(UnitParser.parse(packed)).to include(normalized_unit: 'oz')
        expect(UnitParser.per_unit_price(499.2, packed)).to be_within(0.01).of(1.58)
        expect(build_with_uom('4', '1', 'GAL')).to eq('4x1 GAL')
      end

      it 'changes nothing when the API omits uom' do
        expect(build_with_uom('12', '11.5', nil)).to eq('12x11.5')
      end
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
  # Regression (order #336): Sysco rejects a bad updateOrderV2 with HTTP 200,
  # null data and an `errors` array. We raised "returned nil" and dropped the
  # reason, so the failure could not be diagnosed from the logs.
  describe '#graphql_update_order' do
    before { allow(scraper).to receive(:logger).and_return(Logger.new(nil)) }

    it "raises with Sysco's own error message when the update is rejected" do
      allow(scraper).to receive(:graphql_request).and_return(
        'data' => { 'updateOrderV2' => nil },
        'errors' => [{ 'message' => 'Product 6070898 is not available for seller USBL' }]
      )

      expect { scraper.send(:graphql_update_order, order_id: 'o1', sequence_id: 1, line_items: []) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, /Product 6070898 is not available for seller USBL/)
    end

    it 'returns the updated order when Sysco accepts it' do
      allow(scraper).to receive(:graphql_request).and_return('data' => { 'updateOrderV2' => { 'id' => 'o1' } })

      expect(scraper.send(:graphql_update_order, order_id: 'o1', sequence_id: 1, line_items: [])).to eq('id' => 'o1')
    end
  end

  # Regression (order #336): Sysco started requiring price + commissionBasis
  # on every updateOrderV2 line. Without them nothing could be added to a
  # Sysco order. pricingType/totalPrice must still be left to Sysco.
  describe '#add_to_cart line items' do
    before do
      allow(scraper).to receive(:logger).and_return(Logger.new(nil))
      allow(scraper).to receive(:ensure_api_session!)
      allow(scraper).to receive(:load_api_tokens).and_return(site_id: '019', seller_id: 'USBL')
      allow(scraper).to receive(:graphql_create_order).and_return('id' => 'o1', 'sequenceId' => 1)
      allow(scraper).to receive(:graphql_update_order).and_return(
        'sequenceId' => 2, 'lineItems' => [{ 'productId' => '4279592', 'qty' => 5 }]
      )
    end

    it 'sends price and commissionBasis but leaves pricing type and totals to Sysco' do
      scraper.add_to_cart([{ sku: '4279592', name: 'Sugar', quantity: 5, expected_price: 40.59 }])

      expect(scraper).to have_received(:graphql_update_order) do |line_items:, **|
        expect(line_items).to eq([{ qty: 5, soldAs: 'cs', productId: '4279592', price: 40.59,
                                    commissionBasis: 0, siteId: '019', sellerId: 'USBL' }])
      end
    end

    it 'still sends a numeric price when we have no last-known price' do
      scraper.add_to_cart([{ sku: '4279592', name: 'Sugar', quantity: 5, expected_price: nil }])

      expect(scraper).to have_received(:graphql_update_order) do |line_items:, **|
        expect(line_items.first[:price]).to eq(0.0)
      end
    end
  end

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

  # Regression: KINGAR FLOUR CAKE BLEND (6030537) was stored as "6x2" before
  # build_pack_size re-attached uom, and the nightly price refresh never
  # returns packSize, so it sat out every per-unit comparison for months.
  # Sysco's live payload for it is { pack: "6", size: "2", uom: "LB" }.
  describe '#fetch_pack_sizes' do
    def result(sku, pack, size, uom)
      { 'productId' => sku, 'productInfo' => { 'packSize' => { 'pack' => pack, 'size' => size, 'uom' => uom } } }
    end

    before do
      allow(scraper).to receive(:ensure_api_session!)
      allow(scraper).to receive(:logger).and_return(Logger.new(File::NULL))
    end

    it 'looks SKUs up by item number in one search and builds unit-bearing packs' do
      allow(scraper).to receive(:graphql_search_products)
        .with('6030537 6030552', start: 0, num: 12)
        .and_return('results' => [result('6030537', '6', '2', 'LB'), result('6030552', '6', '5', 'LB')])

      yielded = []
      scraper.fetch_pack_sizes(%w[6030537 6030552]) { |found| yielded << found }

      expect(yielded).to eq([{ '6030537' => '6x2 LB', '6030552' => '6x5 LB' }])
      expect(UnitParser.per_unit_price(66.97, yielded.first['6030537'])).to be_within(0.001).of(0.3488)
    end

    it 'ignores fuzzy matches that are not one of the requested SKUs' do
      allow(scraper).to receive(:graphql_search_products)
        .and_return('results' => [result('1401390', '1', '1', 'EA'), result('6030537', '6', '2', 'LB')])

      yielded = []
      scraper.fetch_pack_sizes(%w[6030537 6030999]) { |found| yielded << found }

      expect(yielded).to eq([{ '6030537' => '6x2 LB' }])
    end

    it 'yields an empty batch rather than raising when a lookup fails' do
      allow(scraper).to receive(:graphql_search_products).and_raise(StandardError, 'boom')

      yielded = []
      scraper.fetch_pack_sizes(%w[6030537]) { |found| yielded << found }

      expect(yielded).to eq([{}])
    end

    it 'batches the requested SKUs' do
      allow(scraper).to receive(:graphql_search_products).and_return('results' => [])

      calls = 0
      scraper.fetch_pack_sizes((1..45).map(&:to_s), batch_size: 20) { calls += 1 }

      expect(calls).to eq(3)
      expect(scraper).to have_received(:graphql_search_products).exactly(3).times
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
