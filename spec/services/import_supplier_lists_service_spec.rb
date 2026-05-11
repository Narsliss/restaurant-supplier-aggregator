require 'rails_helper'

RSpec.describe ImportSupplierListsService do
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
end
