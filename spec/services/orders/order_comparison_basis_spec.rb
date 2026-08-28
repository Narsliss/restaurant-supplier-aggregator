require "rails_helper"

# What each order line was routed on, recorded at placement.
#
# It cannot be recovered afterwards: the comparison recomputes from today's
# data, so a pack weight set next month would silently rewrite what we believed
# last month. And dollars are only claimed where the suppliers' own units
# settled it — the platform does not tell a chef it saved them money on the
# strength of a weight nobody stated.
RSpec.describe Orders::AggregatedListOrderService, "comparison basis" do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:user) { create(:user, current_organization: organization) }

  def build_list(packs, name: "Green Bell Peppers")
    list = create(:aggregated_list, organization: organization, location_id: location.id)
    match = create(:product_match, aggregated_list: list, canonical_name: name)

    packs.each do |supplier_name, price, pack_size|
      supplier = create(:supplier, name: supplier_name)
      supplier_list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
      list.aggregated_list_mappings.find_or_create_by!(supplier_list: supplier_list)
      sli = create(:supplier_list_item, supplier_list: supplier_list, name: name,
                                        price: price, pack_size: pack_size,
                                        supplier_product: create(:supplier_product, supplier: supplier,
                                                                 pack_size: pack_size, current_price: price,
                                                                 in_stock: true))
      create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: supplier)
    end
    [list, match]
  end

  def place(list, match, qty: 2)
    described_class.new(
      user: user, aggregated_list: list,
      quantities: { match.id.to_s => qty.to_s },
      supplier_overrides: {}, uom_overrides: {},
      location: location, delivery_date: Date.tomorrow
    ).create_pending_orders!.first
  end

  it "records an exact basis when the suppliers' own units settled it" do
    list, match = build_list([["US Foods", 30.00, "10 LB"], ["What Chefs Want", 41.00, "10 LB"]])

    orders = place(list, match)
    expect(orders.flat_map(&:order_items).map(&:comparison_basis).uniq).to eq(["exact"])
  end

  it "records an estimated basis when only a guessed weight made it rank" do
    list, match = build_list([["US Foods", 30.00, "10 LB"], ["What Chefs Want", 41.00, "24 CT"]])
    expect(match.comparison_verdict).to eq(:estimated)

    orders = place(list, match)
    expect(orders.flat_map(&:order_items).map(&:comparison_basis).uniq).to eq(["estimated"])
  end

  it "records a case_total basis when nothing could be ranked at all" do
    list, match = build_list([["US Foods", 30.00, "10 SHEET"], ["What Chefs Want", 41.00, "assorted"]],
                             name: "Puff Pastry Dough")
    expect(match.comparison_verdict).to eq(:incomparable)

    orders = place(list, match)
    expect(orders.flat_map(&:order_items).map(&:comparison_basis).uniq).to eq(["case_total"])
  end

  it "records a single basis when only one supplier carries it" do
    list, match = build_list([["US Foods", 30.00, "10 LB"]])

    orders = place(list, match)
    expect(orders.flat_map(&:order_items).map(&:comparison_basis).uniq).to eq(["single"])
  end

  describe "savings claims" do
    it "claims dollars on an exact comparison" do
      list, match = build_list([["US Foods", 30.00, "10 LB"], ["What Chefs Want", 41.00, "10 LB"]])

      orders = place(list, match)
      expect(orders.sum { |o| o.savings_amount.to_f }).to be > 0
    end

    # The line still routes and still shows its ranking. It just does not come
    # with a dollar figure resting on a weight no supplier ever stated.
    it "claims nothing on an estimated one" do
      list, match = build_list([["US Foods", 30.00, "10 LB"], ["What Chefs Want", 41.00, "24 CT"]])

      orders = place(list, match)
      expect(orders.sum { |o| o.savings_amount.to_f }).to eq(0)
    end

    it "claims nothing when only case totals separated them" do
      list, match = build_list([["US Foods", 30.00, "10 SHEET"], ["What Chefs Want", 41.00, "assorted"]],
                               name: "Puff Pastry Dough")

      orders = place(list, match)
      expect(orders.sum { |o| o.savings_amount.to_f }).to eq(0)
    end
  end
end
