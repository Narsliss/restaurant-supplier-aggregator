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
end
