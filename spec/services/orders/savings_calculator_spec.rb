require 'rails_helper'

RSpec.describe Orders::SavingsCalculator do
  def supplier(name)
    Supplier.find_or_create_by!(code: name.parameterize) do |s|
      s.name = name
      s.base_url = "https://example.test"
      s.login_url = "https://example.test/login"
      s.scraper_class = "Scrapers::BaseScraper"
    end
  end

  def product(sup, name:, pack:, price:, unit: nil)
    SupplierProduct.create!(
      supplier: sup, supplier_sku: "#{name}-#{pack}-#{price}".parameterize,
      supplier_name: name, pack_size: pack, current_price: price, price_unit: unit
    )
  end

  def line(sp, unit_price:, quantity: 1)
    OrderItem.new(supplier_product: sp, unit_price: unit_price, quantity: quantity)
  end

  let(:cw)  { supplier("Comparator Warehouse") }
  let(:usf) { supplier("Comparator Foods") }
  let(:ppo) { supplier("Comparator Produce") }
  let(:wcw) { supplier("Comparator Chefs") }
  let(:sys) { supplier("Comparator Sysco Like") }

  # The line that broke the previous design. Alfios bought a 36 lb case of
  # commodity 80% unsalted butter prints at $90.00. Name matching correctly
  # surfaced Vermont Creamery cultured butter ($8.75/lb) and a single retail
  # pound ($5.00/lb) — both genuinely unsalted butter. Benchmarking against the
  # dearest of those claimed $449.70 of savings on a $180 purchase.
  describe 'the butter line' do
    let(:bought)  { product(cw,  name: "80% Unsalted Butter Prints", pack: "36x1 LB Case", price: 90.00) }
    let(:usf_peer) { product(usf, name: "BUTTER, UNSALTED SOLID AA",  pack: "36/1 LB",      price: 90.32) }
    let(:ppo_peer) { product(ppo, name: "UNSALTED BUTTER",            pack: "36x1 LB",      price: 94.00) }
    let(:retail)   { product(wcw, name: "Butter - Solid Unsalted",    pack: "1 LB",         price: 5.00) }
    let(:premium)  { product(sys, name: "Butter Cultured Unsalted",   pack: "12x1 LB",      price: 104.95) }

    let(:peers) { [bought, usf_peer, ppo_peer, retail, premium] }

    it 'excludes the retail pound and the smaller premium case' do
      result = described_class.call(line(bought, unit_price: 90.00, quantity: 2), peers)

      expect(result).to be_comparable
      expect(result.peer_count).to eq(2)
    end

    it 'reports a saving in single dollars, not hundreds' do
      result = described_class.call(line(bought, unit_price: 90.00, quantity: 2), peers)

      # dearest in-band peer is $94.00 per 36 lb; they paid $90.00.
      expect(result.realized).to be_within(0.5).of((94.00 - 90.00) * 2)
      expect(result.realized).to be < 10
      expect(result.missed).to eq(0.0)
    end

    # Documented limitation, not an accident. The benchmark is the dearest
    # comparable peer, so a premium variant that ships in a comparable pack does
    # lift it. The pack band cannot catch this one and the 6x spread gate is the
    # only remaining backstop. Recorded here so it is a known trade, not a
    # surprise the next time a savings figure looks too good.
    it 'is lifted by a premium variant that ships in a comparable pack' do
      big_premium = product(sys, name: "Butter Cultured Unsalted Case", pack: "36x1 LB", price: 314.85)
      result = described_class.call(line(bought, unit_price: 90.00, quantity: 2),
                                    peers + [big_premium])

      expect(result.peer_count).to eq(3)
      expect(result.realized).to be_within(1.0).of((314.85 - 90.00) * 2)
    end
  end

  describe 'a middle pick' do
    let(:bought) { product(cw,  name: "Olive Oil Extra Virgin", pack: "4/3 LT", price: 120.00) }
    let(:cheap)  { product(usf, name: "Olive Oil Extra Virgin", pack: "4/3 LT", price: 80.00) }
    let(:mid)    { product(ppo, name: "Olive Oil Extra Virgin", pack: "4/3 LT", price: 130.00) }
    let(:dear)   { product(wcw, name: "Olive Oil Extra Virgin", pack: "4/3 LT", price: 150.00) }

    it 'credits the move made and still records the gap left' do
      result = described_class.call(line(bought, unit_price: 120.00), [bought, cheap, mid, dear])

      # dearest 150, cheapest 80, paid 120. The two halves always sum to the
      # full market spread, whatever the chef picked.
      expect(result.realized).to be_within(0.5).of(30.0)
      expect(result.missed).to be_within(0.5).of(40.0)
      expect(result.total_spread).to be_within(1.0).of(150.0 - 80.0)
    end

    it 'claims nothing when they bought the dearest' do
      result = described_class.call(line(dear, unit_price: 150.00), [bought, cheap, mid, dear])

      expect(result.realized).to eq(0.0)
      expect(result.missed).to be_within(0.5).of(70.0)
    end
  end

  describe 'catch-weight peers' do
    # The peer quotes a rate per pound. Read as a case total it looks like a
    # $2.35 case of pork butt and undercuts everyone by the weight of the pack.
    it 'prices a per-pound quote across the whole pack' do
      bought = product(usf, name: "Pork Boston Butt", pack: "4x16 LB", price: 100.60)
      sysco  = product(sys, name: "Pork Boston Butt", pack: "4x16#AVG", price: 2.35)

      result = described_class.call(line(bought, unit_price: 100.60), [bought, sysco])

      expect(sysco.comparison_rate * 1024).to be_within(1.0).of(150.40)
      expect(result).to be_comparable
      expect(result.missed).to eq(0.0)
      expect(result.realized).to be_within(1.0).of(150.40 - 100.60)
    end
  end

  describe 'refusing to claim' do
    it 'declines when no peer shares a unit basis' do
      bought = product(cw,  name: "Gloves Nitrile", pack: "4/250 EA", price: 50.15)
      other  = product(usf, name: "Gloves Nitrile", pack: "10 LB",    price: 40.00)

      result = described_class.call(line(bought, unit_price: 50.15), [bought, other])

      expect(result).not_to be_comparable
      expect(result.reason).to eq(:no_comparable_peer)
      expect(result.realized).to eq(0.0)
    end

    it 'declines when the cheapest and dearest cannot be the same product' do
      bought = product(cw,  name: "Saffron Threads", pack: "1 LB", price: 20.00)
      absurd = product(usf, name: "Saffron Threads", pack: "1 LB", price: 900.00)

      result = described_class.call(line(bought, unit_price: 20.00), [bought, absurd])

      expect(result).not_to be_comparable
      expect(result.reason).to eq(:implausible_spread)
    end

    it 'declines when the pack cannot be parsed' do
      bought = product(cw,  name: "Mystery Item", pack: "assorted", price: 10.00)
      other  = product(usf, name: "Mystery Item", pack: "assorted", price: 12.00)

      result = described_class.call(line(bought, unit_price: 10.00), [bought, other])

      expect(result).not_to be_comparable
    end

    it 'keeps a genuinely negotiated price rather than calling it broken' do
      bought = product(cw,  name: "Canola Frying Oil", pack: "1x35 LB", price: 42.54)
      other  = product(usf, name: "Canola Frying Oil", pack: "1x35 LB", price: 42.54)

      # Paid 22% under list — a real contract price, not a data error.
      result = described_class.call(line(bought, unit_price: 33.35), [bought, other])

      expect(result).to be_comparable
      expect(result.realized).to be_within(0.5).of(42.54 - 33.35)
    end
  end

  describe 'a peer from the same supplier' do
    it 'never counts as an alternative' do
      bought  = product(cw, name: "Heavy Cream", pack: "12/1 QT", price: 48.00)
      sibling = product(cw, name: "Heavy Cream Alt", pack: "12/1 QT", price: 90.00)

      result = described_class.call(line(bought, unit_price: 48.00), [bought, sibling])

      expect(result).not_to be_comparable
      expect(result.reason).to eq(:no_comparable_peer)
    end
  end
end
