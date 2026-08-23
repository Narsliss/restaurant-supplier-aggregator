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

    it "does not read a peer's per-pound price as a case price" do
      # $3.90/LB on a 40 lb case is $156.00 — dearer than the $48.74 case bought,
      # even though it wins on price per ounce.
      sp = matched_pair(
        ordered: { name: "GLENVIEW FARMS - CHEESE, CREAM", price: 48.74, pack_size: "6/13.5 OZ" },
        peer: { name: "CREAM CHEESE LOAF", price: 3.90, price_unit: "LB", pack_size: "8/5 LB" }
      )
      order_line(sp, unit_price: 48.74, quantity: 47)

      get missed_savings_reports_path
      expect(response).to have_http_status(:ok)

      expect(response.body).not_to include("$3.90")      # the per-LB quote
      expect(response.body).not_to include("$44.84")     # savings/unit off the mismatch
      expect(response.body).not_to include("$2,107.69")  # 44.84 x 47 units
      expect(response.body).to include("No missed savings found")
    end

    it "reports a catch-weight peer at its case-equivalent when it really is cheaper" do
      # Same $3.90/LB, but a 5 lb case: $19.50 against the $48.74 paid.
      sp = matched_pair(
        ordered: { name: "GLENVIEW FARMS - CHEESE, CREAM", price: 48.74, pack_size: "6/13.5 OZ" },
        peer: { name: "CREAM CHEESE LOAF", price: 3.90, price_unit: "LB", pack_size: "1/5 LB" }
      )
      order_line(sp, unit_price: 48.74, quantity: 2)

      get missed_savings_reports_path
      expect(response).to have_http_status(:ok)

      expect(response.body).to include("$19.50")   # case-equivalent, not $3.90
      expect(response.body).not_to include("$3.90")
      expect(response.body).to include("$58.48")   # (48.74 - 19.50) x 2
      expect(response.body).to include("est.")     # flagged as a derived case price
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
