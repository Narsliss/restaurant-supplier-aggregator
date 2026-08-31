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

  # ORDERING SAFETY — the catch-weight unit fix reaches order creation through
  # exactly two doors, and these pin both.
  #
  #   1. cheapest_supplier decides WHICH supplier lands in the cart
  #   2. estimated_total_price becomes order_items.unit_price, which is sent as
  #      expected_price in build_cart_items and gates verify_cart_matches!
  #
  # Before the fix a Sysco per-pound quote read as a case total, so a $2.35/lb
  # pork butt looked like a $2.35 case: it won routing against a real $100 case
  # and booked the line at $2.35, which is also the number cart verification
  # would have checked against a supplier billing ~$150.
  describe "catch-weight routing and captured price" do
    let(:usf) { create(:supplier, name: "Catch US Foods", case_pricing: false) }
    let(:sysco) { create(:supplier, name: "Catch Sysco", case_pricing: true) }

    let!(:catch_list) do
      list = create(:aggregated_list, organization: organization, location_id: location.id)
      match = create(:product_match, aggregated_list: list, canonical_name: "Pork Boston Butt")

      # US Foods sells the 68 lb case outright for $100.60.
      # Sysco quotes the same case at $2.26 PER POUND — $153.68 for the case.
      # The "8x7-10# LB" weight-range pack is the shape the old regex could not
      # read at all, so the rate was taken for a case total.
      [[usf, "68 LB", 100.60, nil], [sysco, "8x7-10# LB", 2.26, nil]].each do |supplier, pack, price, unit|
        supplier_list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
        list.aggregated_list_mappings.find_or_create_by!(supplier_list: supplier_list)
        sp = create(:supplier_product, supplier: supplier, current_price: price, in_stock: true,
                                       pack_size: pack, price_unit: unit)
        sli = create(:supplier_list_item, supplier_list: supplier_list, name: "Pork Boston Butt",
                                          price: price, pack_size: pack, price_unit: unit,
                                          supplier_product: sp)
        create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: supplier)
      end
      list
    end
    let(:catch_match) { catch_list.product_matches.first }

    def run_catch(quantities)
      described_class.new(
        user: user, aggregated_list: catch_list, quantities: quantities,
        supplier_overrides: {}, uom_overrides: {},
        location: location, delivery_date: Date.tomorrow
      ).create_pending_orders!
    end

    it "does not route to the supplier whose per-pound quote merely looks cheap" do
      run_catch({ catch_match.id.to_s => 1 })
      order = Order.where(organization: organization).order(:created_at).last

      expect(order.supplier).to eq(usf)
    end

    it "captures the per-pound quote as a full case cost, not the rate" do
      sysco_sli = catch_match.product_match_items.find { |i| i.supplier_id == sysco.id }.supplier_list_item

      # 8 pieces averaging 8.5 lb = 68 lb at $2.26/lb.
      expect(sysco_sli.estimated_total_price).to be_within(0.01).of(153.68)
      expect(sysco_sli.estimated_total_price).not_to be_within(1.0).of(2.26)
    end

    it "sends the case cost as expected_price, never the per-pound rate" do
      run_catch({ catch_match.id.to_s => 1 })
      order = Order.where(organization: organization).order(:created_at).last
      item = order.order_items.first

      # unit_price is what build_cart_items hands verify_cart_matches! —
      # a per-pound figure here would trip a false price-changed halt.
      expect(item.unit_price.to_f).to be_within(0.01).of(100.60)
    end

    it "still routes to the genuinely cheaper supplier when the units agree" do
      sysco_sli = catch_match.product_match_items.find { |i| i.supplier_id == sysco.id }.supplier_list_item
      sysco_sli.update!(price: 1.20, price_unit: nil) # $1.20/lb = $81.60 a case

      run_catch({ catch_match.id.to_s => 1 })
      order = Order.where(organization: organization).order(:created_at).last

      expect(order.supplier).to eq(sysco)
      expect(order.order_items.first.unit_price.to_f).to be_within(0.01).of(81.60)
    end
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
