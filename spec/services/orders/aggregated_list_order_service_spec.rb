require "rails_helper"

# Sourcing ONE product from more than one supplier — 5 salads from the cheap
# supplier plus 1 from the pricier one to clear its order minimum.
#
# ORDERING SAFETY: orders are already grouped one-per-supplier, so the two
# lines land in two different Orders. No single order ever repeats a product,
# which is why nothing downstream of order creation had to change.
RSpec.describe Orders::AggregatedListOrderService do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:user) { create(:user, current_organization: organization) }
  let(:cheap_supplier) { create(:supplier, name: "Premiere Produce One") }
  let(:pricey_supplier) { create(:supplier, name: "What Chefs Want") }

  let!(:aggregated_list) do
    list = create(:aggregated_list, organization: organization, location_id: location.id)
    match = create(:product_match, aggregated_list: list, canonical_name: "Salad Mix")

    [[cheap_supplier, 10.00], [pricey_supplier, 12.00]].each do |supplier, price|
      supplier_list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
      list.aggregated_list_mappings.find_or_create_by!(supplier_list: supplier_list)
      sli = create(:supplier_list_item, supplier_list: supplier_list, name: "Salad Mix", price: price,
                                        supplier_product: create(:supplier_product, supplier: supplier,
                                                                                    current_price: price, in_stock: true))
      create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: supplier)
    end
    list
  end
  let(:match) { aggregated_list.product_matches.first }

  def run(quantities:, supplier_overrides: {}, uom_overrides: {})
    described_class.new(
      user: user,
      aggregated_list: aggregated_list,
      quantities: quantities,
      supplier_overrides: supplier_overrides,
      uom_overrides: uom_overrides,
      location: location,
      delivery_date: Date.tomorrow
    ).create_pending_orders!
  end

  describe "one product split across two suppliers" do
    it "creates one order per supplier, each with its own quantity and price" do
      orders, batch_id = run(quantities: {
        match.id.to_s => { cheap_supplier.id.to_s => "5", pricey_supplier.id.to_s => "1" }
      })

      expect(orders.size).to eq(2)
      expect(batch_id).to be_present
      expect(orders.map(&:batch_id).uniq).to eq([batch_id])

      cheap_order = orders.find { |o| o.supplier_id == cheap_supplier.id }
      pricey_order = orders.find { |o| o.supplier_id == pricey_supplier.id }

      expect(cheap_order.order_items.sole).to have_attributes(quantity: 5, unit_price: 10.00, line_total: 50.00)
      expect(pricey_order.order_items.sole).to have_attributes(quantity: 1, unit_price: 12.00, line_total: 12.00)
    end

    it "never puts the same product in one order twice" do
      orders, _ = run(quantities: {
        match.id.to_s => { cheap_supplier.id.to_s => "5", pricey_supplier.id.to_s => "1" }
      })

      orders.each do |order|
        product_ids = order.order_items.map(&:supplier_product_id)
        expect(product_ids).to eq(product_ids.uniq)
      end
    end

    it "keeps each supplier's UOM choice independent" do
      orders, _ = run(
        quantities: { match.id.to_s => { cheap_supplier.id.to_s => "5", pricey_supplier.id.to_s => "1" } },
        uom_overrides: { match.id.to_s => { cheap_supplier.id.to_s => "CS", pricey_supplier.id.to_s => "PC" } }
      )

      expect(orders.find { |o| o.supplier_id == cheap_supplier.id }.order_items.sole.uom).to eq("CS")
      expect(orders.find { |o| o.supplier_id == pricey_supplier.id }.order_items.sole.uom).to eq("PC")
    end

    it "drops a supplier whose quantity is zero" do
      orders, _ = run(quantities: {
        match.id.to_s => { cheap_supplier.id.to_s => "5", pricey_supplier.id.to_s => "0" }
      })

      expect(orders.map(&:supplier_id)).to eq([cheap_supplier.id])
    end
  end

  describe "the pre-split flat param shape" do
    it "still routes a whole quantity to the overridden supplier" do
      orders, _ = run(
        quantities: { match.id.to_s => "3" },
        supplier_overrides: { match.id.to_s => pricey_supplier.id.to_s }
      )

      expect(orders.sole.supplier_id).to eq(pricey_supplier.id)
      expect(orders.sole.order_items.sole.quantity).to eq(3)
    end

    it "falls back to the cheapest supplier with no override" do
      orders, _ = run(quantities: { match.id.to_s => "3" })

      expect(orders.sole.supplier_id).to eq(cheap_supplier.id)
    end
  end
end
