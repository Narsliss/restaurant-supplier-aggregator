require 'rails_helper'

RSpec.describe SupplierListItem, type: :model do
  # Sysco quotes catch-weight items at a rate per pound, and the scraper labels
  # them price_unit "LB". CatalogSearchService built its rows by copying the
  # product's price and nothing else, and PriceClassifiers skipped inference on
  # catalog-search rows — so the rate was read as a case total and divided
  # across the pack a second time. The missed-savings report offered a 64 lb
  # case of pork butt at $1.83 against the $80.80 the chef paid: a claimed
  # saving of 97% of their own invoice, sliding just under the
  # Order::MAX_SAVINGS_MULTIPLE guard.
  describe 'catch-weight pricing carried in from the catalog' do
    # seed_suppliers creates Sysco on boot, so claim the existing row.
    let(:sysco) do
      Supplier.find_or_create_by!(code: 'sysco') { |s| s.name = 'Sysco' }
              .tap { |s| s.update!(case_pricing: true) }
    end
    let(:credential) { create(:supplier_credential, supplier: sysco) }
    let(:list) do
      SupplierList.create!(supplier: sysco, supplier_credential: credential,
                           organization_id: credential.organization_id, name: 'Sysco')
    end

    def product(attrs = {})
      SupplierProduct.create!({ supplier: sysco, supplier_sku: 'CW-1',
                                supplier_name: 'PORK BUTT', current_price: 2.35,
                                pack_size: '4x16#AVG' }.merge(attrs))
    end

    def row(source:, sp:, price_unit: nil, price: 2.35, pack_size: '4x16#AVG')
      list.supplier_list_items.create!(name: 'PORK BUTT', sku: "S-#{source}-#{price_unit || 'nil'}-#{pack_size}",
                                       price: price, pack_size: pack_size,
                                       price_unit: price_unit, supplier_product: sp,
                                       source: source)
    end

    it 'reads the same product the same way from either source' do
      sp = product(price_unit: 'LB')
      guide = row(source: 'order_guide', price_unit: 'LB', sp: sp)
      found = row(source: 'catalog_search', price_unit: 'LB', sp: sp)

      # $2.35 per lb, not $2.35 spread across 64 lb.
      expect(guide.per_unit_price).to be_within(0.0001).of(2.35 / 16)
      expect(found.per_unit_price).to eq(guide.per_unit_price)
      expect(found.estimated_total_price).to be_within(0.01).of(2.35 * 64)
    end

    it 'borrows the unit off the product when the copied row never stored one' do
      sp = product(price_unit: 'LB')
      found = row(source: 'catalog_search', sp: sp)

      expect(found.stated_price_unit).to eq('LB')
      expect(found.per_unit_price).to be_within(0.0001).of(2.35 / 16)
    end

    # The pack alone is enough when nothing upstream labelled the price.
    it 'infers per-lb on a catalog-search row with no unit anywhere' do
      found = row(source: 'catalog_search', sp: product)

      expect(found.per_unit_price).to be_within(0.0001).of(2.35 / 16)
      expect(found).to be_priced_per_weight
    end

    it 'does not borrow the product unit for a row that priced itself' do
      guide = row(source: 'order_guide', sp: product(price_unit: 'LB'), price: 150.40)

      expect(guide.stated_price_unit).to be_nil
    end

    # A fixed-weight pack carries no marker to infer from, so only the unit
    # stated on the product keeps this one honest.
    it 'keeps a stated per-lb unit on a fixed-weight pack' do
      sp = product(supplier_sku: 'CW-2', pack_size: '1x12 LB',
                   current_price: 5.53, price_unit: 'LB')
      found = row(source: 'catalog_search', sp: sp, price: 5.53, pack_size: '1x12 LB')

      expect(found.per_unit_price).to be_within(0.0001).of(5.53 / 16)
      expect(found.estimated_total_price).to be_within(0.01).of(5.53 * 12)
    end

    # Sysco lists a ribeye as "1x4-5 PC" at $18.35/LB. The pack resolves to
    # pieces, not pounds. Converting anyway invented a $5.16 case cost — cheaper
    # than the raw price, and cheap enough to win order routing outright.
    it 'refuses to spread a per-pound rate across a pack measured in pieces' do
      sp = product(supplier_sku: 'CW-4', pack_size: '1x4-5 PC',
                   current_price: 18.35, price_unit: 'LB')
      found = row(source: 'catalog_search', sp: sp, price: 18.35, pack_size: '1x4-5 PC')

      expect(found.estimated_total_price.to_f).to be_within(0.01).of(18.35)
      expect(found.estimated_total_price.to_f).not_to be < 18.35
    end

    it 'still treats a genuine case price as a case price' do
      sp = product(supplier_sku: 'CW-3', pack_size: '12x12 OZ',
                   current_price: 91.85, price_unit: 'CS')
      found = row(source: 'catalog_search', sp: sp, price: 91.85, pack_size: '12x12 OZ')

      expect(found.per_unit_price).to be_within(0.0001).of(91.85 / 144)
      expect(found).not_to be_priced_per_weight
    end
  end

  describe '#link_to_supplier_product!' do
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

    def make_sli(attrs = {})
      supplier_list.supplier_list_items.create!(
        { name: 'Item', sku: 'SKU-1', price: 10.0, pack_size: '1 case' }.merge(attrs)
      )
    end

    def make_sp(attrs = {})
      defaults = {
        supplier: supplier,
        supplier_sku: 'SKU-1',
        supplier_name: 'Catalog Item',
        current_price: 12.50,
        pack_size: '1 case'
      }
      SupplierProduct.create!(defaults.merge(attrs))
    end

    context 'when SLI has a SKU' do
      it 'links via exact SKU match' do
        sp = make_sp(supplier_sku: '20284', supplier_name: 'Spinach - Flat Leaf')
        sli = make_sli(sku: '20284', name: 'Spinach - Flat Leaf')

        sli.link_to_supplier_product!

        expect(sli.reload.supplier_product_id).to eq(sp.id)
      end

      # Regression: SLI with sku=20284 must NOT link to a name-similar SP with
      # sku=20285 ("Spinach - Flat Leaf Each"). The legacy prefix-name fallback
      # would grab the wrong neighbor when the SKU-matching SP didn't yet exist.
      it 'does NOT fall back to prefix name match when SKU is present and lookup fails' do
        wrong_neighbor = make_sp(supplier_sku: '20285', supplier_name: 'Spinach - Flat Leaf Each')
        sli = make_sli(sku: '20284', name: 'Spinach - Flat Leaf', price: nil)

        sli.link_to_supplier_product!

        expect(sli.reload.supplier_product_id).to be_nil
        expect(sli.reload.supplier_product_id).not_to eq(wrong_neighbor.id)
      end

      it 'does NOT fall back to exact name match when SKU is present and lookup fails' do
        same_name_diff_sku = make_sp(supplier_sku: 'OTHER', supplier_name: 'Spinach - Flat Leaf')
        sli = make_sli(sku: '20284', name: 'Spinach - Flat Leaf', price: nil)

        sli.link_to_supplier_product!

        expect(sli.reload.supplier_product_id).to be_nil
        expect(sli.reload.supplier_product_id).not_to eq(same_name_diff_sku.id)
      end

      it 'creates a stub SP when no SKU match exists and price is present' do
        sli = make_sli(sku: '99999', name: 'Brand New Item', price: 5.0)

        expect { sli.link_to_supplier_product! }.to change { SupplierProduct.count }.by(1)

        sp = sli.reload.supplier_product
        expect(sp.supplier_sku).to eq('99999')
        expect(sp.current_price).to eq(5.0)
      end
    end

    context 'when SLI has no SKU' do
      it 'links via exact name match' do
        sp = make_sp(supplier_sku: 'XYZ', supplier_name: 'Vintage Item')
        sli = make_sli(sku: nil, name: 'Vintage Item')

        sli.link_to_supplier_product!

        expect(sli.reload.supplier_product_id).to eq(sp.id)
      end

      it 'links via prefix name match for catalog rows with brand suffix' do
        sp = make_sp(supplier_sku: 'XYZ', supplier_name: 'Cherries - Amarene In Syrup Gelatech')
        sli = make_sli(sku: nil, name: 'Cherries - Amarene In Syrup')

        sli.link_to_supplier_product!

        expect(sli.reload.supplier_product_id).to eq(sp.id)
      end
    end

    it 'is a no-op when already linked' do
      sp = make_sp
      sli = make_sli(supplier_product_id: sp.id)
      other = make_sp(supplier_sku: 'OTHER', supplier_name: 'Other')

      expect { sli.link_to_supplier_product! }.not_to(change { sli.reload.supplier_product_id })
      expect(sli.supplier_product_id).to eq(sp.id)
      expect(sli.supplier_product_id).not_to eq(other.id)
    end

    # Regression: two concurrent imports for the same (supplier_id, sku) both
    # miss the initial find_by and race to create!. The validates :uniqueness
    # check raises RecordInvalid; the DB unique index raises RecordNotUnique.
    # Either way the method must recover and link to the winning row instead
    # of bubbling the exception up and leaving the SLI unlinked.
    context 'when a concurrent insert wins the (supplier_id, sku) race' do
      it 'recovers from RecordInvalid (Rails uniqueness check) and links to the winner' do
        sli = make_sli(sku: 'RACE-1', name: 'Race Item', price: 9.99)
        winning_sp = nil
        call_count = 0
        allow(SupplierProduct).to receive(:find_by).and_wrap_original do |orig, *args|
          call_count += 1
          if call_count == 1
            winning_sp = make_sp(supplier_sku: 'RACE-1', supplier_name: 'Race Winner')
            nil
          else
            orig.call(*args)
          end
        end

        expect { sli.link_to_supplier_product! }.not_to raise_error
        expect(sli.reload.supplier_product_id).to eq(winning_sp.id)
        expect(SupplierProduct.where(supplier_id: supplier.id, supplier_sku: 'RACE-1').count).to eq(1)
      end

      it 'recovers from RecordNotUnique (DB index) and links to the winner' do
        sli = make_sli(sku: 'RACE-2', name: 'Race Item', price: 9.99)
        winning_sp = make_sp(supplier_sku: 'RACE-2', supplier_name: 'Race Winner')

        allow(SupplierProduct).to receive(:find_by).and_wrap_original do |orig, *args|
          if args.first == { supplier_id: supplier.id, supplier_sku: 'RACE-2' } && !@found_yet
            @found_yet = true
            nil
          else
            orig.call(*args)
          end
        end
        allow_any_instance_of(SupplierProduct).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

        expect { sli.link_to_supplier_product! }.not_to raise_error
        expect(sli.reload.supplier_product_id).to eq(winning_sp.id)
      end
    end
  end

  # Regression: order #145 — catch-weight items need an explicit "estimated"
  # signal on builder/review screens since the invoice depends on actual weight.
  describe '#priced_per_weight? and #catch_weight_note' do
    it 'builds the note for an explicit per-LB item' do
      sli = build(:supplier_list_item, price: 2.00, price_unit: 'LB', pack_size: '4/10 LB')
      expect(sli.priced_per_weight?).to be true
      expect(sli.catch_weight_note).to eq('~est. 40 lb @ $2.00/lb')
    end

    it 'shows one decimal for fractional pack weights' do
      sli = build(:supplier_list_item, price: 2.00, price_unit: 'LB', pack_size: '2/8.3 LB')
      expect(sli.catch_weight_note).to eq('~est. 16.6 lb @ $2.00/lb')
    end

    it 'is nil for case-priced items' do
      sli = build(:supplier_list_item, price: 32.19, price_unit: 'CS', pack_size: '12/200 EA')
      expect(sli.priced_per_weight?).to be false
      expect(sli.catch_weight_note).to be_nil
    end

    it 'is nil when the pack cannot be parsed into pounds' do
      sli = build(:supplier_list_item, price: 2.00, price_unit: 'LB', pack_size: 'MARKET WEIGHT')
      expect(sli.catch_weight_note).to be_nil
    end
  end
end
