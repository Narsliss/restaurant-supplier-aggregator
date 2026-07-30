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
