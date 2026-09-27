require 'rails_helper'

RSpec.describe ImportSupplierProductsService do
  describe '#backlink_list_items_to_canonical_sps' do
    let(:supplier) { create(:supplier) }
    let(:credential) { create(:supplier_credential, supplier: supplier) }
    let(:supplier_list) do
      SupplierList.create!(
        supplier: supplier,
        supplier_credential: credential,
        organization_id: credential.organization_id,
        name: 'Test Order Guide'
      )
    end
    let(:service) { described_class.new(credential) }

    def make_sp(sku:, name: 'Catalog Item', price: 10.0)
      SupplierProduct.create!(
        supplier: supplier,
        supplier_sku: sku,
        supplier_name: name,
        current_price: price,
        pack_size: '1 case'
      )
    end

    def make_sli(sku:, supplier_product:, name: 'List Item', price: 9.0)
      supplier_list.supplier_list_items.create!(
        name: name,
        sku: sku,
        price: price,
        pack_size: '1 case',
        supplier_product_id: supplier_product&.id
      )
    end

    # Regression: SLI #9864 in production was linked to SP #1362 (sku 20285,
    # "Spinach - Flat Leaf Each") via prefix-name fallback. The catalog later
    # scraped SP #49783 (sku 20284, "Spinach - Flat Leaf") but no back-link
    # ran, so the SLI stayed pointed at the wrong SP. The next catalog import
    # should re-link it to the canonical SP.
    it 're-points a mis-linked SLI to the canonical SP for its SKU' do
      wrong_sp = make_sp(sku: '20285', name: 'Spinach - Flat Leaf Each')
      canonical_sp = make_sp(sku: '20284', name: 'Spinach - Flat Leaf')
      sli = make_sli(sku: '20284', supplier_product: wrong_sp)

      service.send(:backlink_list_items_to_canonical_sps, ['20284'])

      expect(sli.reload.supplier_product_id).to eq(canonical_sp.id)
    end

    it 'links a previously unlinked SLI when its SKU now resolves to an SP' do
      canonical_sp = make_sp(sku: '20284', name: 'Spinach - Flat Leaf')
      sli = make_sli(sku: '20284', supplier_product: nil)

      service.send(:backlink_list_items_to_canonical_sps, ['20284'])

      expect(sli.reload.supplier_product_id).to eq(canonical_sp.id)
    end

    it 'does not modify SLI price, name, or stock columns' do
      wrong_sp = make_sp(sku: '20285', name: 'Wrong Neighbor', price: 99.99)
      make_sp(sku: '20284', name: 'Spinach - Flat Leaf', price: 26.95)
      sli = make_sli(sku: '20284', supplier_product: wrong_sp, name: 'Spinach - Flat Leaf', price: 9.15)

      expect { service.send(:backlink_list_items_to_canonical_sps, ['20284']) }
        .not_to change { sli.reload.attributes.slice('name', 'price', 'in_stock', 'pack_size') }
    end

    it 'leaves an SLI alone when its current link is already canonical' do
      canonical_sp = make_sp(sku: '20284', name: 'Spinach - Flat Leaf')
      sli = make_sli(sku: '20284', supplier_product: canonical_sp)

      expect { service.send(:backlink_list_items_to_canonical_sps, ['20284']) }
        .not_to change { sli.reload.updated_at }
    end

    it 'is a no-op when no SP matches the touched SKUs' do
      sli = make_sli(sku: '99999', supplier_product: make_sp(sku: '99999'))

      expect { service.send(:backlink_list_items_to_canonical_sps, ['no-such-sku']) }
        .not_to change { sli.reload.supplier_product_id }
    end

    it 'only relinks SLIs in the same supplier' do
      other_supplier = create(:supplier)
      other_cred = create(:supplier_credential, supplier: other_supplier)
      other_list = SupplierList.create!(
        supplier: other_supplier,
        supplier_credential: other_cred,
        organization_id: other_cred.organization_id,
        name: 'Other'
      )
      other_sp = SupplierProduct.create!(
        supplier: other_supplier, supplier_sku: '20284',
        supplier_name: 'Different Supplier Same SKU', current_price: 5.0, pack_size: '1 case'
      )
      other_sli = other_list.supplier_list_items.create!(
        name: 'X', sku: '20284', price: 1.0, pack_size: '1', supplier_product_id: other_sp.id
      )

      make_sp(sku: '20284', name: 'Our Canonical')

      expect { service.send(:backlink_list_items_to_canonical_sps, ['20284']) }
        .not_to change { other_sli.reload.supplier_product_id }
    end
  end

  describe '#sync_prices_to_list_items' do
    let(:supplier) { create(:supplier) }
    let(:credential) { create(:supplier_credential, supplier: supplier) }
    let(:supplier_list) do
      SupplierList.create!(
        supplier: supplier,
        supplier_credential: credential,
        organization_id: credential.organization_id,
        name: 'Test Order Guide'
      )
    end
    let(:service) { described_class.new(credential) }

    def make_sp(sku:, name: 'Catalog Item', price: 10.0, in_stock: true)
      SupplierProduct.create!(
        supplier: supplier,
        supplier_sku: sku,
        supplier_name: name,
        current_price: price,
        pack_size: '1 case',
        in_stock: in_stock
      )
    end

    def make_sli(sku:, supplier_product:, name: 'List Item', price: 9.0, in_stock: true)
      supplier_list.supplier_list_items.create!(
        name: name,
        sku: sku,
        price: price,
        pack_size: '1 case',
        in_stock: in_stock,
        supplier_product_id: supplier_product&.id
      )
    end

    # Regression: this is the second half of the spinach incident. The
    # mis-linked SLI (sku 20284 pointing at SP sku 20285) was about to be
    # repaired by backlink_list_items_to_canonical_sps, but sync_prices_to_list_items
    # ran first and stamped the wrong SP's $9.15 onto the SLI before the
    # link was fixed.
    it 'skips a mis-linked SLI whose SKU does not match the SP being synced' do
      wrong_sp = make_sp(sku: '20285', name: 'Spinach - Flat Leaf Each', price: 9.15)
      sli = make_sli(sku: '20284', supplier_product: wrong_sp, name: 'Spinach - Flat Leaf', price: 26.95)

      service.send(:sync_prices_to_list_items, [{ id: wrong_sp.id }])

      sli.reload
      expect(sli.price).to eq(26.95)
      expect(sli.previous_price).to be_nil
    end

    it 'still syncs a correctly-linked SLI when SKU matches the SP' do
      canonical_sp = make_sp(sku: '20284', name: 'Spinach - Flat Leaf', price: 26.95)
      sli = make_sli(sku: '20284', supplier_product: canonical_sp, name: 'Spinach - Flat Leaf', price: 24.50)

      service.send(:sync_prices_to_list_items, [{ id: canonical_sp.id }])

      sli.reload
      expect(sli.price).to eq(26.95)
      expect(sli.previous_price).to eq(24.50)
    end

    it 'does not push stock changes to a mis-linked SLI either' do
      wrong_sp = make_sp(sku: '20285', name: 'Spinach - Flat Leaf Each', in_stock: false)
      sli = make_sli(sku: '20284', supplier_product: wrong_sp, in_stock: true)

      service.send(:sync_prices_to_list_items, [{ id: wrong_sp.id }])

      # SupplierListItem#in_stock delegates to the linked SP, so we check the
      # raw column to confirm the sync didn't write through to the SLI itself.
      expect(sli.reload.read_attribute(:in_stock)).to be(true)
    end

    it 'syncs SLIs that have no SKU (legacy rows fall through SKU guard)' do
      sp = make_sp(sku: '20284', name: 'No-SKU List Item', price: 26.95)
      sli = make_sli(sku: nil, supplier_product: sp, price: 9.99)

      service.send(:sync_prices_to_list_items, [{ id: sp.id }])

      expect(sli.reload.price).to eq(26.95)
    end
  end

  describe '#import_catalog_deep' do
    let(:supplier) { create(:supplier) }
    let(:credential) { create(:supplier_credential, supplier: supplier) }
    let(:service) { described_class.new(credential) }

    def deep_scraper(batches = [])
      scraper = instance_double('DeepScraper')
      allow(scraper).to receive(:scrape_catalog_deep) do |&blk|
        batches.each { |b| blk.call(b) }
        []
      end
      scraper
    end

    it 'never runs miss tracking — a deep crawl must not discontinue anything' do
      expect(service).not_to receive(:record_misses_for_unseen_products)

      service.import_catalog_deep(scraper: deep_scraper)
    end

    it 'no-ops for a scraper that does not support deep import' do
      plain = Object.new # genuinely does not respond to scrape_catalog_deep

      result = service.import_catalog_deep(scraper: plain)

      expect(result[:imported]).to eq(0)
    end

    # The user-facing win: a full crawl re-sees items that had gone stale and
    # reinstates them (un-discontinues), so e.g. WCW snapper reappears in search.
    it 'reinstates a previously discontinued product that reappears in the crawl' do
      sp = SupplierProduct.create!(
        supplier: supplier, supplier_sku: 'SNAP1', supplier_name: 'Snapper',
        current_price: 20.0, pack_size: '1 case',
        discontinued: true, discontinued_at: 1.week.ago, in_stock: false
      )
      batch = [{ supplier_sku: 'SNAP1', supplier_name: 'Snapper Red', current_price: 22.0,
                 pack_size: '1 LB', in_stock: true, category: 'Seafood' }]

      service.import_catalog_deep(scraper: deep_scraper([batch]))

      expect(sp.reload.discontinued).to be(false)
    end
  end

  # Sep 25 2026: US Foods answers some SKUs with an error and a "0" price
  # (1104 discontinued, 1102 gone, 1106 reserved for other customers). The
  # refresh stored that 0 as the price, so discontinued items showed as
  # orderable at $0.00 on chefs' lists.
  # Regression: KINGAR FLOUR CAKE BLEND (Sysco 6030537) was stored as "6x2"
  # before build_pack_size re-attached uom, and the nightly refresh never
  # returns packSize — so it sat out every per-unit comparison.
  describe '#heal_unitless_pack_sizes' do
    let(:supplier) { create(:supplier) }
    let(:credential) { create(:supplier_credential, supplier: supplier) }
    let(:service) { described_class.new(credential) }
    let(:supplier_list) do
      SupplierList.create!(supplier: supplier, supplier_credential: credential,
                           organization_id: credential.organization_id, name: 'Guide')
    end
    let!(:sp) do
      SupplierProduct.create!(supplier: supplier, supplier_sku: '6030537', current_price: 66.97,
                              supplier_name: 'KINGAR FLOUR CAKE BLEND UNBLEACHED', pack_size: '6x2')
    end
    let!(:sli) do
      supplier_list.supplier_list_items.create!(name: 'KINGAR FLOUR CAKE BLEND UNBLEACHED', sku: '6030537',
                                                price: 66.97, pack_size: '6x2', supplier_product_id: sp.id)
    end

    def scraper_returning(packs)
      requested = []
      scraper = Object.new
      scraper.define_singleton_method(:fetch_pack_sizes) do |skus, &block|
        requested.concat(skus)
        block.call(packs.slice(*skus))
      end
      [scraper, requested]
    end

    it 're-attaches the unit to the product and its list item so both parse' do
      scraper, = scraper_returning('6030537' => '6x2 LB')

      result = service.heal_unitless_pack_sizes(scraper: scraper)

      expect(result).to include(checked: 1, healed: 1, list_items_healed: 1, skipped_price_move: 0)
      expect(sp.reload.pack_size).to eq('6x2 LB')
      expect(sli.reload.pack_size).to eq('6x2 LB')
      expect(sli.per_unit_price).to be_within(0.001).of(0.3488)
    end

    it 'only looks up packs that have no unit' do
      SupplierProduct.create!(supplier: supplier, supplier_sku: '6030552', supplier_name: 'FLOUR WW', pack_size: '6x5 LB')
      SupplierProduct.create!(supplier: supplier, supplier_sku: '6030553', supplier_name: 'MEAT', pack_size: '2x5#AVG')
      scraper, requested = scraper_returning({})

      service.heal_unitless_pack_sizes(scraper: scraper)

      expect(requested).to eq(['6030537'])
    end

    it 'leaves the pack alone when the supplier changed the numbers, not just added a unit' do
      scraper, = scraper_returning('6030537' => '6x2.5 LB')

      service.heal_unitless_pack_sizes(scraper: scraper)

      expect(sp.reload.pack_size).to eq('6x2')
      expect(sli.reload.pack_size).to eq('6x2')
    end

    # The order builder carries estimated_total_price into the cart. A
    # per-pound price meeting a newly-weighted pack would reprice the line
    # (66.97/lb x 12 lb), so the repair must stand down.
    it 'skips the row when the new pack would change what the order builder charges' do
      sli.update_columns(price_unit: 'LB')
      scraper, = scraper_returning('6030537' => '6x2 LB')

      result = service.heal_unitless_pack_sizes(scraper: scraper)

      expect(result).to include(healed: 0, skipped_price_move: 1)
      expect(sp.reload.pack_size).to eq('6x2')
      expect(sli.reload.pack_size).to eq('6x2')
    end

    it 'does not touch a list item linked to this product under a different SKU' do
      sli.update_columns(sku: '9999999')
      scraper, = scraper_returning('6030537' => '6x2 LB')

      service.heal_unitless_pack_sizes(scraper: scraper)

      expect(sp.reload.pack_size).to eq('6x2 LB')
      expect(sli.reload.pack_size).to eq('6x2')
    end

    it 'does nothing for a scraper that cannot look packs up' do
      expect(service.heal_unitless_pack_sizes(scraper: Object.new)).to include(checked: 0, healed: 0)
      expect(sp.reload.pack_size).to eq('6x2')
    end
  end

  describe '#apply_refresh_updates — supplier said there is no price' do
    let(:supplier) { create(:supplier) }
    let(:credential) { create(:supplier_credential, supplier: supplier) }
    let(:service) { described_class.new(credential) }
    let(:supplier_list) do
      SupplierList.create!(supplier: supplier, supplier_credential: credential,
                           organization_id: credential.organization_id, name: 'Guide')
    end
    let!(:sp) do
      SupplierProduct.create!(supplier: supplier, supplier_sku: '6292155', supplier_name: 'TOMATO, HEIRLOOM',
                              current_price: 39.05, pack_size: '10 LB')
    end
    let!(:sli) do
      supplier_list.supplier_list_items.create!(name: 'TOMATO, HEIRLOOM', sku: '6292155', price: 0,
                                                pack_size: '10 LB', supplier_product_id: sp.id)
    end

    def apply(update)
      service.instance_variable_set(:@existing_by_sku, { sp.supplier_sku => sp })
      service.send(:apply_refresh_updates, [update])
    end

    it 'marks a discontinued product discontinued and clears its price everywhere' do
      apply(supplier_sku: '6292155', current_price: nil, price_unit: nil, unavailable: true, discontinued: true)

      expect(sp.reload).to have_attributes(discontinued: true, current_price: nil, previous_price: 39.05)
      expect(sp.discontinued_at).to be_present
      expect(sli.reload.price).to be_nil
    end

    it 'clears only the catalog price for an item reserved for other customers' do
      sli.update!(price: 12.0)

      apply(supplier_sku: '6292155', current_price: nil, price_unit: nil, unavailable: true, discontinued: false)

      expect(sp.reload).to have_attributes(discontinued: false, current_price: nil)
      # The chef's own account may still price it — their list sync decides.
      expect(sli.reload.price).to eq(12.0)
    end

    it 'applies an ordinary price exactly as before' do
      apply(supplier_sku: '6292155', current_price: 41.0, price_unit: 'CS')

      expect(sp.reload).to have_attributes(current_price: 41.0, previous_price: 39.05, discontinued: false)
    end
  end

  # Sep 27 2026: Sysco's Prices API answers the 12 lb provolone loaf (8413064)
  # with case.netPrice 5.534 and productInfo.isCatchWeight true — a rate per
  # pound, which the scraper labels 'LB'. The catalog import threw the label
  # away (only the ID refresh saved it, and the refresh skips SKUs the term
  # search found), so the product kept 'CS' and Alfio's matched list showed a
  # $5.53 case at $0.03/oz marked BEST against ~$60 peers.
  describe '#import_batch — the unit a catalog price is quoted in' do
    let(:sysco) { Supplier.find_by(code: 'sysco') || create(:supplier, code: 'sysco', name: 'Sysco') }
    let(:credential) { create(:supplier_credential, supplier: sysco) }
    let(:service) { described_class.new(credential) }

    # Shape of Scrapers::SyscoScraper#parse_catalog_product's output for the
    # live payload above.
    let(:provolone) do
      { supplier_sku: '8413064', supplier_name: 'PACKER CHEESE LOAF PROVOLONE',
        current_price: 5.534, price_unit: 'LB', pack_size: '1x12 LB', in_stock: true }
    end

    def import(items)
      service.send(:prepare_import_indexes!)
      service.send(:import_batch, items)
    end

    context 'when the product already exists labelled as a case' do
      let!(:sp) do
        SupplierProduct.create!(supplier: sysco, supplier_sku: '8413064', supplier_name: 'PACKER CHEESE LOAF PROVOLONE',
                                current_price: 5.53, price_unit: 'CS', pack_size: '1x12 LB')
      end

      it 'stores the per-pound label the scrape carried' do
        import([provolone])

        expect(sp.reload.price_unit).to eq('LB')
      end

      it 'compares the loaf per pound on a catalog-search list row' do
        list = SupplierList.create!(supplier: sysco, supplier_credential: credential,
                                    organization_id: credential.organization_id, name: 'Matched')
        row = list.supplier_list_items.create!(name: 'PACKER CHEESE LOAF PROVOLONE', sku: '8413064', price: 5.53,
                                               pack_size: '1x12 LB', source: 'catalog_search',
                                               supplier_product_id: sp.id)

        import([provolone])

        # $5.53/lb = $0.35/oz — not $5.53 spread over 192 oz ($0.03/oz).
        expect(row.reload.per_unit_price).to be_within(0.001).of(5.53 / 16)
      end

      it 'keeps the label when the scrape brought no price to go with it' do
        import([provolone.merge(current_price: nil, price_unit: 'CS')])

        expect(sp.reload.price_unit).to eq('CS')
      end
    end

    # Blast radius: ~18.8k Sysco products have no stored unit and lean on pack
    # inference. The catalog path must not start stamping 'CS'/'EA' on them.
    it 'never writes a case or each label — only per-pound' do
      sp = SupplierProduct.create!(supplier: sysco, supplier_sku: '1111111', supplier_name: 'BEEF GRND 81/19',
                                   current_price: 42.0, pack_size: '4x10#AVG')
      lb = SupplierProduct.create!(supplier: sysco, supplier_sku: '2222222', supplier_name: 'PORK BUTT',
                                   current_price: 2.26, price_unit: 'LB', pack_size: '8x7-10# LB')

      import([
               { supplier_sku: '1111111', supplier_name: 'BEEF GRND 81/19', current_price: 43.0,
                 price_unit: 'CS', pack_size: '4x10#AVG', in_stock: true },
               { supplier_sku: '2222222', supplier_name: 'PORK BUTT', current_price: 2.30,
                 price_unit: 'CS', pack_size: '8x7-10# LB', in_stock: true },
               { supplier_sku: '3333333', supplier_name: 'NEW CASE ITEM', current_price: 20.0,
                 price_unit: 'CS', pack_size: '6x2 LB', in_stock: true }
             ])

      expect(sp.reload).to have_attributes(current_price: 43.0, price_unit: nil)
      expect(lb.reload.price_unit).to eq('LB')
      expect(SupplierProduct.find_by(supplier: sysco, supplier_sku: '3333333').price_unit).to be_nil
    end

    it 'labels a new catch-weight product per pound' do
      import([provolone])

      expect(SupplierProduct.find_by(supplier: sysco, supplier_sku: '8413064').price_unit).to eq('LB')
    end

    it 'leaves other suppliers\' stored units alone' do
      other = create(:supplier)
      other_service = described_class.new(create(:supplier_credential, supplier: other))
      sp = SupplierProduct.create!(supplier: other, supplier_sku: 'X1', supplier_name: 'Cheese',
                                   current_price: 60.0, pack_size: '4x5 LB')

      other_service.send(:prepare_import_indexes!)
      other_service.send(:import_batch, [provolone.merge(supplier_sku: 'X1', supplier_name: 'Cheese', current_price: 61.0)])

      expect(sp.reload).to have_attributes(current_price: 61.0, price_unit: nil)
    end
  end

  # Sysco third-party items must be priced and ordered under their own seller
  # (order #337); the catalog search is where that seller is learned.
  describe '#import_batch — the seller an item is sold by' do
    let(:sysco) { Supplier.find_by(code: 'sysco') || create(:supplier, code: 'sysco', name: 'Sysco') }
    let(:credential) { create(:supplier_credential, supplier: sysco) }
    let(:service) { described_class.new(credential) }
    let(:pineapple) do
      { supplier_sku: '6081093', supplier_name: 'DOLE Fancy Sliced Pineapple', seller_id: '2011',
        current_price: 33.22, pack_size: '12x8 OZ', in_stock: true }
    end

    def import(items)
      service.send(:prepare_import_indexes!)
      service.send(:import_batch, items)
    end

    it 'stores the seller on a new product' do
      import([pineapple])

      expect(SupplierProduct.find_by(supplier: sysco, supplier_sku: '6081093').supplier_seller_id).to eq('2011')
    end

    it 'fills in the seller on an existing product' do
      sp = SupplierProduct.create!(supplier: sysco, supplier_sku: '6081093', supplier_name: 'DOLE Fancy Sliced Pineapple')

      import([pineapple])

      expect(sp.reload.supplier_seller_id).to eq('2011')
    end

    it 'stores the seller group Sysco reports' do
      import([pineapple.merge(supplier_sku: '4279592', supplier_name: 'Domino Sugar', seller_id: 'USBL', seller_group: 'LOCAL_SALES')])

      expect(SupplierProduct.find_by(supplier: sysco, supplier_sku: '4279592'))
        .to have_attributes(supplier_seller_id: 'USBL', supplier_seller_group: 'LOCAL_SALES')
    end

    it 'keeps a known seller when a scrape carries none' do
      sp = SupplierProduct.create!(supplier: sysco, supplier_sku: '6081093', supplier_name: 'DOLE Fancy Sliced Pineapple',
                                   supplier_seller_id: '2011')

      import([pineapple.except(:seller_id)])

      expect(sp.reload.supplier_seller_id).to eq('2011')
    end
  end
end
