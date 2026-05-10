require 'rails_helper'

RSpec.describe SupplierListItem, type: :model do
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
  end
end
