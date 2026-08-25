require 'rails_helper'

RSpec.describe ImportSupplierListsService do
  describe '#upsert_list — per-location dedup' do
    let(:user) { create(:user, :with_organization) }
    let(:org) { user.current_organization }
    let(:supplier) { create(:supplier) }
    let(:loc_a) { create(:location, organization: org, user: user, name: 'Alfios') }
    let(:loc_b) { create(:location, organization: org, user: user, name: 'Noche') }
    let(:cred_a) { create(:supplier_credential, supplier: supplier, user: user, organization_id: org.id, location_id: loc_a.id) }
    let(:cred_b) { create(:supplier_credential, supplier: supplier, user: user, organization_id: org.id, location_id: loc_b.id) }

    # Regression: WCW + PPO scrapers emit a static remote_id="order-guide".
    # Before the location_id was added to the dedup key, two credentials at
    # different restaurants in the same org collapsed into one SupplierList
    # row pinned to whichever location scraped first — see the Noche-vs-alfios
    # incident in the audit report. Each restaurant must keep its own list.
    it 'creates separate supplier_lists for two credentials at different locations with the same remote_id' do
      list_data = { remote_id: 'order-guide', name: 'Order Guide', items: [] }

      service_a = described_class.new(cred_a)
      service_a.send(:upsert_list, list_data)

      service_b = described_class.new(cred_b)
      service_b.send(:upsert_list, list_data)

      rows = SupplierList.where(supplier: supplier, organization: org, remote_list_id: 'order-guide')
      expect(rows.count).to eq(2)
      expect(rows.pluck(:location_id)).to match_array([loc_a.id, loc_b.id])
    end

    it 'reuses the same supplier_list on repeat scrape of the same credential' do
      list_data = { remote_id: 'order-guide', name: 'Order Guide', items: [] }
      service = described_class.new(cred_a)
      service.send(:upsert_list, list_data)
      service.send(:upsert_list, list_data)

      rows = SupplierList.where(supplier: supplier, organization: org, remote_list_id: 'order-guide', location_id: loc_a.id)
      expect(rows.count).to eq(1)
    end
  end

  describe '#upsert_list — rotated order-guide adoption' do
    # Regression: US Foods regenerates the account order guide under a new
    # OG-<number> remote id roughly monthly with the same items inside.
    # Keying strictly by remote_list_id made each rotation a brand-new
    # SupplierList whose items could never rejoin their own product matches
    # (one item per supplier per match), so every generation appended a
    # duplicate copy of the guide to the org's matched list — see the
    # 1,336-line alfios matched-list incident.
    let(:user) { create(:user, :with_organization) }
    let(:org) { user.current_organization }
    let(:supplier) { create(:supplier) }
    let(:location) { create(:location, organization: org, user: user) }
    let(:credential) { create(:supplier_credential, supplier: supplier, user: user, organization_id: org.id, location_id: location.id) }
    let(:service) { described_class.new(credential) }

    def og_items(skus)
      skus.map.with_index do |sku, i|
        { sku: sku, name: "Item #{sku}", price: 10.0 + i, pack_size: '6/10 LB', position: i }
      end
    end

    def import(remote_id, skus, scraped_ids: [remote_id])
      service.instance_variable_set(:@scraped_remote_ids, scraped_ids)
      service.send(:upsert_list, { remote_id: remote_id, name: "Order Guide #{remote_id}", items: og_items(skus) })
    end

    it 'adopts the vanished predecessor row when a rotated OG id arrives with overlapping SKUs' do
      import('OG-100', %w[A1 A2 A3])
      old_list = SupplierList.find_by(remote_list_id: 'OG-100')
      old_item_id = old_list.supplier_list_items.find_by(sku: 'A1').id

      import('OG-200', %w[A1 A2 A4])

      expect(SupplierList.where(supplier: supplier, organization: org).count).to eq(1)
      old_list.reload
      expect(old_list.remote_list_id).to eq('OG-200')
      # Overlapping SKUs keep their SupplierListItem rows (and everything
      # referencing them); only the dropped SKU's row goes away.
      expect(old_list.supplier_list_items.find_by(sku: 'A1').id).to eq(old_item_id)
      expect(old_list.supplier_list_items.pluck(:sku)).to match_array(%w[A1 A2 A4])
    end

    it 'keeps product match items alive across a rotation' do
      import('OG-100', %w[A1 A2 A3])
      sli = SupplierList.find_by(remote_list_id: 'OG-100').supplier_list_items.find_by(sku: 'A1')
      pmi = create(:product_match_item, supplier_list_item: sli)

      import('OG-200', %w[A1 A2 A3])

      expect(ProductMatchItem.exists?(pmi.id)).to be(true)
      expect(pmi.reload.supplier_list_item.supplier_list.remote_list_id).to eq('OG-200')
    end

    it 'creates a new row when SKU overlap is below the threshold' do
      import('OG-100', %w[A1 A2 A3])
      import('OG-200', %w[B1 B2 B3])

      expect(SupplierList.where(supplier: supplier, organization: org).pluck(:remote_list_id))
        .to match_array(%w[OG-100 OG-200])
    end

    it 'never adopts a guide still present in the current scrape' do
      import('OG-100', %w[A1 A2 A3])
      import('OG-200', %w[A1 A2 A3], scraped_ids: %w[OG-100 OG-200])

      expect(SupplierList.where(supplier: supplier, organization: org).pluck(:remote_list_id))
        .to match_array(%w[OG-100 OG-200])
    end

    it 'picks the best-overlapping candidate when several stale generations exist' do
      import('OG-100', %w[A1 A2 A3])
      import('OG-150', %w[B1 B2 B3])

      import('OG-300', %w[B1 B2 B4])

      lists = SupplierList.where(supplier: supplier, organization: org)
      expect(lists.pluck(:remote_list_id)).to match_array(%w[OG-100 OG-300])
      expect(lists.find_by(remote_list_id: 'OG-300').supplier_list_items.pluck(:sku))
        .to match_array(%w[B1 B2 B4])
    end

    it 'ignores non-rotating remote id patterns' do
      import('SL-100', %w[A1 A2 A3])
      import('SL-200', %w[A1 A2 A3])

      expect(SupplierList.where(supplier: supplier, organization: org).pluck(:remote_list_id))
        .to match_array(%w[SL-100 SL-200])
    end
  end

  describe '#refresh_linked_product (private)' do
    let(:supplier) { create(:supplier) }
    let(:credential) { create(:supplier_credential, supplier: supplier) }
    let(:supplier_list) do
      SupplierList.create!(
        supplier: supplier,
        supplier_credential: credential,
        organization_id: credential.organization_id,
        name: 'Order Guide'
      )
    end
    let(:service) { described_class.new(credential) }

    def make_sp(sku:, in_stock:, price: 10.0)
      SupplierProduct.create!(
        supplier: supplier,
        supplier_sku: sku,
        supplier_name: 'Spinach - Flat Leaf',
        current_price: price,
        pack_size: '4/2.5LB CS',
        in_stock: in_stock
      )
    end

    def make_sli(sku:, supplier_product:, raw_in_stock:, price: 10.0)
      sli = supplier_list.supplier_list_items.build(
        name: 'Spinach - Flat Leaf', sku: sku, price: price, pack_size: '4/2.5LB CS',
        supplier_product_id: supplier_product&.id
      )
      sli.in_stock = raw_in_stock
      sli.save!
      sli
    end

    # Regression: SLI#in_stock is a delegating reader that returns the
    # linked SP's value. Using it here used to copy SP.in_stock back to
    # itself — a no-op — so order-guide stock updates never reached the
    # SP. For case_pricing suppliers where catalog returns nil for stock
    # (e.g. WCW), an SP that ever went out-of-stock stayed that way
    # forever, even after the order guide reported availability again.
    it 'propagates the SLI raw in_stock column into the linked SP' do
      sp = make_sp(sku: '20284', in_stock: false)
      sli = make_sli(sku: '20284', supplier_product: sp, raw_in_stock: true)

      service.send(:refresh_linked_product, sli)

      expect(sp.reload.in_stock).to be(true)
    end

    it 'flips SP to out-of-stock when the order guide reports unavailability' do
      sp = make_sp(sku: '20284', in_stock: true)
      sli = make_sli(sku: '20284', supplier_product: sp, raw_in_stock: false)

      service.send(:refresh_linked_product, sli)

      expect(sp.reload.in_stock).to be(false)
    end

    it 'leaves SP stock alone when the SLI raw column is nil' do
      sp = make_sp(sku: '20284', in_stock: true)
      sli = supplier_list.supplier_list_items.create!(
        name: 'Spinach', sku: '20284', price: 26.95, pack_size: '4/2.5LB CS',
        supplier_product_id: sp.id
      )
      sli.update_columns(in_stock: nil)

      expect { service.send(:refresh_linked_product, sli.reload) }
        .not_to change { sp.reload.in_stock }
    end
  end

  describe '#upsert_item — stale mis-link healing' do
    let(:supplier) { create(:supplier) }
    let(:credential) { create(:supplier_credential, supplier: supplier) }
    let(:supplier_list) do
      SupplierList.create!(
        supplier: supplier,
        supplier_credential: credential,
        organization_id: credential.organization_id,
        name: 'Order Guide'
      )
    end
    let(:service) { described_class.new(credential) }

    def make_sp(sku:, name:, in_stock: true, price: 10.0)
      SupplierProduct.create!(
        supplier: supplier, supplier_sku: sku, supplier_name: name,
        current_price: price, pack_size: '1 case', in_stock: in_stock
      )
    end

    # Regression: legacy SLIs linked via the old name-fallback could be
    # stuck on an off-by-one neighbor SP, and ImportSupplierListsService
    # never re-evaluated the link because supplier_product_id wasn't nil.
    # When the order guide returns the SLI's real SKU and the canonical SP
    # already exists, upsert_item should now drop the bad link and resolve
    # to the canonical SP.
    it 're-links a stale SLI to the canonical SP when one exists' do
      wrong_sp = make_sp(sku: '20802', name: 'Peppers - Red Bell Standard', in_stock: false)
      canonical_sp = make_sp(sku: '20803', name: 'Peppers - Red Bell Premium', in_stock: true)
      sli = supplier_list.supplier_list_items.create!(
        name: 'Peppers - Red Bell Premium', sku: '20803', price: 35.00,
        pack_size: '1 case', supplier_product_id: wrong_sp.id
      )

      service.send(:upsert_item, supplier_list, {
        sku: '20803', name: 'Peppers - Red Bell Premium', price: 35.00,
        pack_size: '1 case', in_stock: true, quantity: 1, position: 1
      }, { '20803' => sli }, Set.new)

      expect(sli.reload.supplier_product_id).to eq(canonical_sp.id)
    end

    # When the catalog hasn't seen the SLI's SKU yet, link_to_supplier_product!
    # creates a stub SP so the SLI isn't stranded on the wrong neighbor.
    it 'creates a stub SP and links to it when no canonical SP exists for the SKU' do
      wrong_sp = make_sp(sku: '20802', name: 'Peppers - Red Bell Standard', in_stock: false)
      sli = supplier_list.supplier_list_items.create!(
        name: 'Peppers - Red Bell Premium', sku: '20803', price: 35.00,
        pack_size: '1 case', supplier_product_id: wrong_sp.id
      )

      expect {
        service.send(:upsert_item, supplier_list, {
          sku: '20803', name: 'Peppers - Red Bell Premium', price: 35.00,
          pack_size: '1 case', in_stock: true, quantity: 1, position: 1
        }, { '20803' => sli }, Set.new)
      }.to change { SupplierProduct.where(supplier_id: supplier.id, supplier_sku: '20803').count }.from(0).to(1)

      sli.reload
      new_sp = SupplierProduct.find_by(supplier_id: supplier.id, supplier_sku: '20803')
      expect(sli.supplier_product_id).to eq(new_sp.id)
    end

    it 'leaves a correctly-linked SLI alone' do
      sp = make_sp(sku: '20284', name: 'Spinach - Flat Leaf')
      sli = supplier_list.supplier_list_items.create!(
        name: 'Spinach - Flat Leaf', sku: '20284', price: 26.95,
        pack_size: '4/2.5LB CS', supplier_product_id: sp.id
      )

      expect {
        service.send(:upsert_item, supplier_list, {
          sku: '20284', name: 'Spinach - Flat Leaf', price: 26.95,
          pack_size: '4/2.5LB CS', in_stock: true, quantity: 1, position: 1
        }, { '20284' => sli }, Set.new)
      }.not_to change { sli.reload.supplier_product_id }
    end
  end

  describe 'catch-weight prices (per-LB quotes)' do
    let(:supplier) { create(:supplier) }
    let(:credential) { create(:supplier_credential, supplier: supplier) }
    let(:supplier_list) do
      SupplierList.create!(
        supplier: supplier,
        supplier_credential: credential,
        organization_id: credential.organization_id,
        name: 'Order Guide'
      )
    end
    let(:service) { described_class.new(credential) }

    def make_pair(price:, pack_size:, price_unit:, sp_price: nil, sp_unit: nil)
      sp = SupplierProduct.create!(
        supplier: supplier, supplier_sku: '7993187',
        supplier_name: 'BLOCK & BARREL CHEESE GOUDA SMOKED',
        current_price: sp_price, price_unit: sp_unit, pack_size: pack_size
      )
      sli = supplier_list.supplier_list_items.create!(
        name: 'Gouda Smoked', sku: '7993187', price: price,
        pack_size: pack_size, price_unit: price_unit, supplier_product_id: sp.id
      )
      [sp, sli]
    end

    # Regression: Sysco quotes catch-weight items per pound. The list importer
    # converted that to a case total AND propagated price_unit='LB', so
    # SupplierProduct#per_unit_price divided the case total by 16 again — the
    # item read as $5.46 x 12 / 16 = $4.10 per POUND of a 12 lb case. The
    # catalog importer and VerifyItemPriceJob both cache the price as quoted;
    # this path has to agree with them or the same SKU flips convention
    # depending on which job ran last.
    it 'stores the quoted per-LB price, not a case total, when the unit is a weight' do
      sp, sli = make_pair(price: 5.46, pack_size: '2x6#', price_unit: 'LB')

      service.send(:refresh_linked_product, sli)

      expect(sp.reload.current_price.to_f).to eq(5.46)
      expect(sp.price_unit).to eq('LB')
    end

    it 'gives a catch-weight product a sane per-oz rate and case estimate' do
      sp, sli = make_pair(price: 5.46, pack_size: '2x6#', price_unit: 'LB')

      service.send(:refresh_linked_product, sli)
      sp.reload

      # $5.46/lb is $0.34/oz — not the $0.0284/oz a case-total reading produced.
      expect(sp.per_unit_price.to_f).to be_within(0.001).of(0.34125)
      expect(sp.estimated_case_price.to_f).to be_within(0.01).of(65.52)
    end

    it 'still converts to a case total for container-priced items' do
      sp, sli = make_pair(price: 26.95, pack_size: '4/2.5LB CS', price_unit: 'CS')

      service.send(:refresh_linked_product, sli)

      expect(sp.reload.current_price.to_f).to eq(26.95)
    end
  end

  describe '#extreme_price_change? (private)' do
    let(:supplier) { create(:supplier) }
    let(:credential) { create(:supplier_credential, supplier: supplier) }
    let(:service) { described_class.new(credential) }

    it 'blocks a genuinely wild swing' do
      expect(service.send(:extreme_price_change?, 10.0, 900.0, '4/2.5 LB')).to be(true)
    end

    it 'blocks a collapse to a fraction of the old price' do
      expect(service.send(:extreme_price_change?, 100.0, 5.0, '4/2.5 LB')).to be(true)
    end

    it 'allows an ordinary fluctuation' do
      expect(service.send(:extreme_price_change?, 10.0, 14.0, '4/2.5 LB')).to be(false)
    end

    # Regression: a per-LB price being corrected to its case total is a 10-20x
    # jump — exactly the shape this guard blocked. Freezing the low figure left
    # the item undercutting every competitor by the pack weight, permanently,
    # since no later import could get past the guard either.
    it 'allows a per-LB price being corrected to the case total' do
      expect(service.send(:extreme_price_change?, 13.69, 136.90, '1x10 LB')).to be(false)
      expect(service.send(:extreme_price_change?, 9.56, 191.20, '1x20 LB')).to be(false)
    end

    it 'still blocks a big jump that does not match the pack size' do
      expect(service.send(:extreme_price_change?, 13.69, 136.90, '1x30 LB')).to be(true)
    end

    it 'blocks a big jump when the pack size is unparseable' do
      expect(service.send(:extreme_price_change?, 13.69, 136.90, 'ASSORTED')).to be(true)
    end
  end

  describe '#infer_per_unit_pricing! (private)' do
    let(:supplier) { create(:supplier) }
    let(:credential) { create(:supplier_credential, supplier: supplier) }
    let(:supplier_list) do
      SupplierList.create!(
        supplier: supplier, supplier_credential: credential,
        organization_id: credential.organization_id, name: 'Order Guide'
      )
    end
    let(:service) { described_class.new(credential) }

    def sli_with(pack_size:, price:)
      supplier_list.supplier_list_items.create!(
        name: 'Onions', sku: '111', price: price, pack_size: pack_size
      )
    end

    # Regression: UnitParser reports "#" packs under their own unit key, so
    # gating the heuristic on "lb" skipped Sysco's entire "2x6#" catalogue.
    it 'infers per-LB pricing on a "#" pack' do
      item = sli_with(pack_size: '5x10#', price: 6.48)

      service.send(:infer_per_unit_pricing!, item)

      expect(item.reload.price_unit).to eq('lb')
    end

    it 'still infers per-LB pricing on an "LB" pack' do
      item = sli_with(pack_size: '5x10 LB', price: 6.48)

      service.send(:infer_per_unit_pricing!, item)

      expect(item.reload.price_unit).to eq('lb')
    end

    it 'leaves a plausible case price alone' do
      item = sli_with(pack_size: '5x10#', price: 48.00)

      service.send(:infer_per_unit_pricing!, item)

      expect(item.reload.price_unit).to be_blank
    end
  end
end
