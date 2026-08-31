require 'rails_helper'

RSpec.describe ComparisonCandidate do
  def supplier(name)
    Supplier.find_or_create_by!(code: name.parameterize) do |s|
      s.name = name
      s.base_url = "https://example.test"
      s.login_url = "https://example.test/login"
      s.scraper_class = "Scrapers::BaseScraper"
    end
  end

  def product(sup, name:, price: 50.0, pack: "12/1 LB", product_id: nil)
    SupplierProduct.create!(supplier: sup, supplier_sku: "#{name}-#{sup.id}-#{price}".parameterize,
                            supplier_name: name, pack_size: pack, current_price: price,
                            product_id: product_id)
  end

  let(:org) { create(:organization) }
  let(:location) { create(:location, organization: org) }
  let(:cw) { supplier("Peer Warehouse") }
  let(:usf) { supplier("Peer Foods") }
  let(:ppo) { supplier("Peer Produce") }

  describe '.peers_for' do
    it 'includes peers the chef paired on their own matched list' do
      bought = product(cw,  name: "Butter Unsalted")
      peer   = product(usf, name: "Butter Unsalted AA", price: 52.0)

      list = create(:aggregated_list, organization: org, location_id: location.id)
      match = create(:product_match, aggregated_list: list, match_status: "manual")
      [[cw, bought], [usf, peer]].each do |sup, sp|
        sl = create(:supplier_list, supplier: sup, organization: org, location: location)
        sli = create(:supplier_list_item, supplier_list: sl, name: sp.supplier_name, supplier_product: sp)
        create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: sup)
      end

      expect(described_class.peers_for([bought])[bought.id].map(&:id)).to eq([peer.id])
    end

    it 'ignores a pairing the chef rejected' do
      bought = product(cw,  name: "Butter Unsalted")
      peer   = product(usf, name: "Butter Unsalted AA", price: 52.0)

      list = create(:aggregated_list, organization: org, location_id: location.id)
      match = create(:product_match, aggregated_list: list, match_status: "rejected")
      [[cw, bought], [usf, peer]].each do |sup, sp|
        sl = create(:supplier_list, supplier: sup, organization: org, location: location)
        sli = create(:supplier_list_item, supplier_list: sl, name: sp.supplier_name, supplier_product: sp)
        create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: sup)
      end

      expect(described_class.peers_for([bought])[bought.id]).to be_empty
    end

    it 'combines the spine, chef curation and automatic candidates without duplicates' do
      spine_product = Product.create!(name: "Butter")
      bought = product(cw,  name: "Butter Unsalted", product_id: spine_product.id)
      via_spine = product(usf, name: "Butter Unsalted AA", price: 52.0, product_id: spine_product.id)
      via_auto  = product(ppo, name: "Unsalted Butter", price: 54.0)

      described_class.create!(supplier_product: bought, candidate_supplier_product: via_auto,
                              similarity: 0.9, source: "auto_basket")
      # the same peer arriving twice must not be counted twice
      described_class.create!(supplier_product: bought, candidate_supplier_product: via_spine,
                              similarity: 0.8, source: "auto_basket")

      ids = described_class.peers_for([bought])[bought.id].map(&:id)
      expect(ids).to match_array([via_spine.id, via_auto.id])
    end

    # ProductMatch already allows one item per supplier, and ComparisonCandidate
    # validates the same. The spine has no such rule: a rotated order guide
    # leaves two rows from one supplier on one Product, and comparing a supplier
    # against itself is not an alternative.
    it 'never returns a peer from the same supplier, even off the spine' do
      spine_product = Product.create!(name: "Butter")
      bought  = product(cw, name: "Butter Unsalted", product_id: spine_product.id)
      product(cw, name: "Butter Unsalted Old Guide", price: 52.0, product_id: spine_product.id)

      expect(described_class.peers_for([bought])[bought.id]).to be_empty
    end

    it 'drops discontinued and unpriced peers' do
      bought = product(cw, name: "Butter Unsalted")
      dead   = product(usf, name: "Butter Unsalted AA", price: 52.0)
      dead.update!(discontinued: true)
      described_class.create!(supplier_product: bought, candidate_supplier_product: dead,
                              similarity: 0.9, source: "auto_basket")

      expect(described_class.peers_for([bought])[bought.id]).to be_empty
    end
  end

  it 'refuses to store a same-supplier pairing' do
    a = product(cw, name: "Butter A")
    b = product(cw, name: "Butter B", price: 51.0)

    candidate = described_class.new(supplier_product: a, candidate_supplier_product: b,
                                    similarity: 0.9, source: "auto_basket")

    expect(candidate).not_to be_valid
    expect(candidate.errors[:candidate_supplier_product]).to be_present
  end
end
