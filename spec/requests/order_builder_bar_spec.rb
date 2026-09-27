require "rails_helper"

# The order builder's bottom bar (Carmin, Sep 27 2026: "I have no idea how many
# items from performance I have in my cart … there needs to be some sort of
# clear cart button"): per-supplier case counts against the case minimum, a
# Clear cart button, the restaurant's own minimums, and no expired saved date.
RSpec.describe "Order builder bar", type: :request do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:other_location) { create(:location, organization: organization) }
  let(:chef) do
    user = create(:user, current_organization: organization)
    membership = create(:membership, user: user, organization: organization, role: "chef", active: true)
    membership.membership_locations.create!(location: location)
    user
  end
  let(:supplier) { create(:supplier) }
  let!(:subscription) { create(:subscription, user: chef, organization_id: organization.id) }
  let!(:credential) do
    create(:supplier_credential, user: chef, organization: organization, location: location, supplier: supplier, status: "active")
  end
  let!(:aggregated_list) do
    list = create(:aggregated_list, organization: organization, location_id: location.id)
    supplier_list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
    list.aggregated_list_mappings.find_or_create_by!(supplier_list: supplier_list)
    sli = create(:supplier_list_item, supplier_list: supplier_list, name: "Chicken Breast", price: 68.90,
                                      supplier_product: create(:supplier_product, supplier: supplier, current_price: 68.90, in_stock: true))
    match = create(:product_match, aggregated_list: list, canonical_name: "Chicken Breast")
    create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: supplier)
    list
  end

  def requirement(type, value, location: nil)
    SupplierRequirement.create!(supplier: supplier, requirement_type: type, numeric_value: value, location: location,
                                error_message: "Minimum {{minimum}} cases required.")
  end

  def page
    get order_builder_aggregated_list_path(aggregated_list)
    Nokogiri::HTML(response.body)
  end

  before { sign_in chef }

  it "shows each supplier's case count against its case minimum" do
    requirement("case_minimum", 20)

    labels = page.css("[data-supplier-case-label='#{supplier.id}']")

    expect(labels).not_to be_empty
    expect(labels.map { |l| l["data-case-minimum"] }.uniq).to eq(["20"])
    expect(labels.first.text.strip).to eq("0 / 20 cases")
  end

  it "still shows a plain case count for a supplier with no minimums" do
    labels = page.css("[data-supplier-case-label='#{supplier.id}']")

    expect(labels.first.text.strip).to eq("0 cases")
    expect(page.text).to include("No minimum")
  end

  it "uses this restaurant's minimums, not another restaurant's" do
    requirement("order_minimum", 250, location: other_location)
    requirement("order_minimum", 100)

    labels = page.css("[data-supplier-minimum-label='#{supplier.id}']").map { |l| l.text.strip }

    expect(labels.uniq).to eq(["/ $100"])
  end

  it "has a Clear cart button" do
    expect(page.css("[data-clear-cart]").map(&:text)).to all(include("Clear cart"))
  end

  it "passes a supplier's own delivery dates, or its reason there are none, to the date badges" do
    msg = "You are not currently set up for deliveries. Please contact your Sales Representative."
    credential.update_columns(available_delivery_dates: [], delivery_dates_error: msg, delivery_dates_fetched_at: Time.current)

    json = JSON.parse(page.at_css("[data-controller='order-builder']")["data-order-builder-api-delivery-dates-value"])

    expect(json[supplier.id.to_s]).to include("dates" => [], "error" => msg)
  end

  it "doesn't restore a saved delivery date that has passed" do
    CurrentOrder.create!(user: chef, aggregated_list: aggregated_list, delivery_date: Date.current - 30,
                         state: { aggregated_list.product_matches.first.id.to_s => [{ "supplierId" => supplier.id.to_s, "qty" => 2, "uom" => "CS" }] })

    dates = page.css("input[name='delivery_date']").map { |i| i["value"] }

    expect(dates).to all(be_blank)
  end

  it "restores a saved delivery date that is still ahead" do
    CurrentOrder.create!(user: chef, aggregated_list: aggregated_list, delivery_date: Date.current + 3,
                         state: { aggregated_list.product_matches.first.id.to_s => [{ "supplierId" => supplier.id.to_s, "qty" => 2, "uom" => "CS" }] })

    dates = page.css("input[name='delivery_date']").map { |i| i["value"] }

    expect(dates).to include((Date.current + 3).iso8601)
  end
end
