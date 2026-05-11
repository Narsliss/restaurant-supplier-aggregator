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
end
