require "rails_helper"

# Reporting accuracy regressions found 2026-07-29 on the location report:
#   1. Top Products showed a single BLANK row aggregating every builder-created
#      item (123 distinct products, $8,995 spent) because those items have a
#      NULL product_name and the query grouped on that raw column.
#   2. "% saved" exceeded 100% (savings > spent) off one corrupt savings row.
RSpec.describe "Reporting accuracy", type: :request do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:owner) do
    user = create(:user, current_organization: organization)
    membership = create(:membership, user: user, organization: organization, role: "owner", active: true)
    membership.membership_locations.create!(location: location)
    user
  end
  let!(:subscription) { create(:subscription, user: owner, organization_id: organization.id) }
  let(:supplier) { create(:supplier) }
  let!(:credential) do
    create(:supplier_credential, user: owner, organization: organization, location: location,
                                 supplier: supplier, status: "active")
  end
  # Owner onboarding requires a restaurant AND a second team member
  let!(:teammate) do
    create(:membership, user: create(:user), organization: organization, role: "chef", active: true)
  end

  before { sign_in owner }

  def submitted_order(items:)
    order = create(:order, user: owner, organization: organization, location: location,
                           supplier: supplier, status: "submitted", submitted_at: 1.day.ago)
    items.each do |attrs|
      sp = create(:supplier_product, supplier: supplier, supplier_name: attrs[:supplier_name],
                                     supplier_sku: attrs[:sku], current_price: attrs[:price])
      item = create(:order_item, order: order, supplier_product: sp,
                                 quantity: 1, unit_price: attrs[:price])
      # Simulate the builder's bulk insert, which skipped the name snapshot
      item.update_columns(product_name: nil, product_sku: nil) if attrs[:nameless]
    end
    order.recalculate_totals!
    order
  end

  describe "Top Products with nameless items" do
    it "lists each product separately instead of collapsing them into one blank row" do
      submitted_order(items: [
        { supplier_name: "BEEF SHORT RIB CHUCK", sku: "SR-1", price: 573.00, nameless: true },
        { supplier_name: "SHRIMP 16/20 PEELED", sku: "SH-1", price: 70.95, nameless: true },
        { supplier_name: "HERB BASIL FRESH", sku: "HB-1", price: 17.50, nameless: false }
      ])

      get location_reports_path(location_id: location.id)
      expect(response).to have_http_status(:ok)

      # Every product is named — the nameless ones fall back to the live product
      expect(response.body).to include("BEEF SHORT RIB CHUCK")
      expect(response.body).to include("SHRIMP 16/20 PEELED")
      expect(response.body).to include("HERB BASIL FRESH")
    end
  end

  describe "savings percentage" do
    it "never renders above 100% even when stored savings exceed spend" do
      order = submitted_order(items: [{ supplier_name: "PEELED GARLIC", sku: "PG-1", price: 233.80 }])
      # The order #80 shape: corrupt frozen savings snapshot
      order.update_columns(savings_amount: 4_738.37)

      get orders_path
      expect(response).to have_http_status(:ok)

      percentages = response.body.scan(/([\d,]+\.\d)%\s*saved/).flatten.map { |p| p.delete(",").to_f }
      expect(percentages).to all(be <= 100.0)
    end
  end

  # Missed-savings regression found 2026-08-23: the dashboard offered
  # "GLENVIEW FARMS $48.74 paid / $3.90 at Chef's Warehouse / save $44.84 per
  # unit / $2,107.69 total" — a case price set against a per-LB one. The peer's
  # case-equivalent was the whole point of ProductMatch#cheapest_supplier's
  # ranking, but the report read the raw :price back out of the winning hash.
  describe "Missed savings" do
    let(:peer_supplier) { create(:supplier) }

    # Wires up one matched product: what the chef bought, and one peer's quote.
    def matched_pair(ordered:, peer:)
      agg = create(:aggregated_list, organization: organization, location_id: location.id,
                                     created_by: owner, list_type: "matched", match_status: "matched")
      match = create(:product_match, aggregated_list: agg)

      ordered_sp = create(:supplier_product, supplier: supplier, supplier_name: ordered[:name],
                                             current_price: ordered[:price], pack_size: ordered[:pack_size])
      add_match_item(match, supplier, ordered.merge(supplier_product: ordered_sp))
      add_match_item(match, peer_supplier, peer.merge(supplier_product: create(:supplier_product,
        supplier: peer_supplier, supplier_name: peer[:name], current_price: peer[:price],
        pack_size: peer[:pack_size])))

      ordered_sp
    end

    def add_match_item(match, item_supplier, attrs)
      list = create(:supplier_list, supplier: item_supplier, organization: organization, location: location)
      item = create(:supplier_list_item, supplier_list: list, supplier_product: attrs[:supplier_product],
                                         name: attrs[:name], price: attrs[:price],
                                         price_unit: attrs[:price_unit], pack_size: attrs[:pack_size])
      create(:product_match_item, product_match: match, supplier_list_item: item, supplier: item_supplier)
    end

    def order_line(supplier_product, unit_price:, quantity:, line_total: nil)
      order = create(:order, user: owner, organization: organization, location: location,
                             supplier: supplier, status: "submitted", submitted_at: 1.day.ago)
      item = create(:order_item, order: order, supplier_product: supplier_product,
                                 product_name: supplier_product.supplier_name,
                                 quantity: quantity, unit_price: unit_price)
      # OrderItem recomputes line_total on validation, so a corrupt snapshot has
      # to be written past the callback — same trick as the savings-percentage spec.
      item.update_columns(line_total: line_total) if line_total
      order.recalculate_totals!
      item
    end

    it "prices a per-pound peer at their rate for the quantity ordered, not their sticker" do
      # $3.90/LB is $0.24/oz. The case bought holds 81 oz, so the same quantity
      # from them runs $19.75 — not the $3.90 the dashboard used to print, and not
      # their own 40 lb case price either.
      sp = matched_pair(
        ordered: { name: "GLENVIEW FARMS - CHEESE, CREAM", price: 48.74, pack_size: "6/13.5 OZ" },
        peer: { name: "CREAM CHEESE LOAF", price: 3.90, price_unit: "LB", pack_size: "8/5 LB" }
      )
      order_line(sp, unit_price: 48.74, quantity: 47)

      get missed_savings_reports_path
      expect(response).to have_http_status(:ok)

      expect(response.body).to include("$19.75")       # their rate x the ordered case's 81 oz
      expect(response.body).to include("$0.24/oz")     # the rate itself, shown for context
      expect(response.body).to include("8/5 LB")       # and the pack it has to be bought in
      expect(response.body).to include("$28.99")       # 48.74 - 19.75 per case
      expect(response.body).to match(/\$1,362\.\d\d/)  # x 47 cases

      expect(response.body).not_to include("$3.90")      # the raw per-LB quote
      expect(response.body).not_to include("$44.84")     # savings/unit off the old mismatch
      expect(response.body).not_to include("$2,107.69")  # 44.84 x 47
    end

    it "does not let the peer's own case size change the comparison" do
      # Same $3.90/LB rate, 5 lb case instead of 40 lb. What's being priced is the
      # chef's quantity, so the per-case figures come out identical to the above.
      sp = matched_pair(
        ordered: { name: "GLENVIEW FARMS - CHEESE, CREAM", price: 48.74, pack_size: "6/13.5 OZ" },
        peer: { name: "CREAM CHEESE LOAF", price: 3.90, price_unit: "LB", pack_size: "1/5 LB" }
      )
      order_line(sp, unit_price: 48.74, quantity: 2)

      get missed_savings_reports_path
      expect(response).to have_http_status(:ok)

      expect(response.body).to include("$19.75")
      expect(response.body).to include("$28.99")
      expect(response.body).to include("1/5 LB")
      expect(response.body).to match(/\$57\.9\d/)  # 28.99 x 2
    end

    it "falls back to the peer's case cost when there is no shared per-unit basis" do
      # Unparseable packs leave nothing to compare per ounce, so case cost is the
      # best comparison available — and no rate line is shown, because there isn't one.
      sp = matched_pair(
        ordered: { name: "AVANTI - EMPANADA DISCS", price: 66.94, pack_size: "assorted" },
        peer: { name: "EMPANADA DISCS", price: 49.45, pack_size: "assorted" }
      )
      order_line(sp, unit_price: 66.94, quantity: 4)

      get missed_savings_reports_path
      expect(response).to have_http_status(:ok)

      expect(response.body).to include("$49.45")
      expect(response.body).to include("$69.96")   # (66.94 - 49.45) x 4
      expect(response.body).not_to include("/oz")
    end

    it "sums savings per line instead of extrapolating one average across every unit" do
      sp = matched_pair(
        ordered: { name: "MONARCH - FLOUR, HIGH GLUTEN", price: 50.00, pack_size: "1/50 LB" },
        peer: { name: "HIGH GLUTEN FLOUR", price: 40.00, pack_size: "1/50 LB" }
      )
      order_line(sp, unit_price: 50.00, quantity: 2)  # saves 10.00 x 2
      order_line(sp, unit_price: 44.00, quantity: 1)  # saves  4.00 x 1

      get missed_savings_reports_path
      expect(response).to have_http_status(:ok)

      expect(response.body).to include("$24.00")      # per-line truth
      expect(response.body).not_to include("$21.00")  # AVG(47.00) - 40.00, x 3 units
    end

    it "shows the unit count the total is built from" do
      # $8.00/unit over 3 units is $24.00 — without the count, a row's total has no
      # visible denominator and reads as one enormous per-order saving.
      sp = matched_pair(
        ordered: { name: "MONARCH - FLOUR, HIGH GLUTEN", price: 50.00, pack_size: "1/50 LB" },
        peer: { name: "HIGH GLUTEN FLOUR", price: 40.00, pack_size: "1/50 LB" }
      )
      order_line(sp, unit_price: 50.00, quantity: 2)
      order_line(sp, unit_price: 50.00, quantity: 1)

      get missed_savings_reports_path
      expect(response).to have_http_status(:ok)

      expect(response.body).to include(">Units<")
      row = response.body[%r{<tbody.*?</tbody>}m]
      expect(row).to match(/>3</)        # units, whole — not "3.0"
      expect(row).to include("$10.00")   # save/unit
      expect(row).to include("$30.00")   # total
    end

    it "does not clip long product names on the full report" do
      # The 200px cap belonged to the compact block embedded in other reports; on
      # its own page a name like this one has room to wrap.
      long_name = "GLENVIEW FARMS - CHEESE, CREAM SOFT RIPENED DOUBLE CREME BRIE WHEEL"
      sp = matched_pair(
        ordered: { name: long_name, price: 48.74, pack_size: "6/13.5 OZ" },
        peer: { name: "BRIE WHEEL", price: 30.00, pack_size: "6/13.5 OZ" }
      )
      order_line(sp, unit_price: 48.74, quantity: 2)

      get missed_savings_reports_path
      expect(response).to have_http_status(:ok)

      name_cell = response.body[%r{<td[^>]*>\s*#{Regexp.escape(long_name)}}m]
      expect(name_cell).to be_present
      expect(name_cell).not_to include("truncate")
      expect(name_cell).not_to include("max-w-")
    end

    it "says the comparison uses today's prices against past orders" do
      sp = matched_pair(
        ordered: { name: "MONARCH - FLOUR, HIGH GLUTEN", price: 50.00, pack_size: "1/50 LB" },
        peer: { name: "HIGH GLUTEN FLOUR", price: 40.00, pack_size: "1/50 LB" }
      )
      order_line(sp, unit_price: 50.00, quantity: 1)

      get missed_savings_reports_path
      expect(response.body).to include("today's supplier pricing")
      expect(response.body).to include("what you paid on past orders")
    end

    it "drops a line whose claimed saving is implausible against what was paid" do
      sp = matched_pair(
        ordered: { name: "PATUXENT FARMS - PORK BUTT", price: 57.20, pack_size: "1/24 LB" },
        peer: { name: "PORK BUTT BONELESS", price: 5.00, pack_size: "1/24 LB" }
      )
      # A corrupt line_total (the order #80 shape) makes the spread 52 x 10 = $520
      # look like 52x the $10 recorded as paid.
      order_line(sp, unit_price: 57.20, quantity: 10, line_total: 10.00)

      get missed_savings_reports_path
      expect(response).to have_http_status(:ok)

      expect(response.body).not_to include("$522.00")
      expect(response.body).to include("No missed savings found")
    end
  end

  describe "OrdersHelper#savings_percentage" do
    it "expresses savings as a share of what the orders would have cost" do
      helper = Class.new { include OrdersHelper }.new

      expect(helper.savings_percentage(25, 75)).to eq(25.0)   # would have paid 100
      expect(helper.savings_percentage(4_738.37, 233.80)).to be <= 100.0
      expect(helper.savings_percentage(0, 500)).to be_nil
      expect(helper.savings_percentage(50, 0)).to eq(100.0)
    end
  end
end
