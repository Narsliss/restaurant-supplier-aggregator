require "rails_helper"

# Gap 1 (Carmin, Oct 19 2026): an item a supplier calls out of stock can't be
# put in a cart from the order builder. US Foods is the exception: its "out"
# only warns (D1), the same rule as the review page.
RSpec.describe "Order builder: out-of-stock cells", type: :request do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:chef) do
    user = create(:user, current_organization: organization)
    membership = create(:membership, user: user, organization: organization, role: "chef", active: true)
    membership.membership_locations.create!(location: location)
    user
  end
  let(:mobile_ua) { { "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" } }
  let(:cw) { create(:supplier, name: "OOS Chefs Warehouse", scraper_class: "Scrapers::ChefsWarehouseScraper") }
  let(:usf) { create(:supplier, name: "OOS US Foods", scraper_class: "Scrapers::UsFoodsScraper") }
  let(:sysco) { create(:supplier, name: "OOS Sysco", scraper_class: "Scrapers::SyscoScraper") }
  let!(:subscription) { create(:subscription, user: chef, organization_id: organization.id) }

  # Walnuts: out at CW and at US Foods, in at Sysco.
  let!(:aggregated_list) do
    list = create(:aggregated_list, organization: organization, location_id: location.id)
    match = create(:product_match, aggregated_list: list, canonical_name: "Walnut Halves", match_status: "confirmed")
    [[cw, 42.0, false], [usf, 44.0, false], [sysco, 46.0, true]].each do |supplier, price, in_stock|
      create(:supplier_credential, user: chef, organization: organization, location: location, supplier: supplier)
      supplier_list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
      list.aggregated_list_mappings.find_or_create_by!(supplier_list: supplier_list)
      sp = create(:supplier_product, supplier: supplier, current_price: price, in_stock: in_stock)
      sli = create(:supplier_list_item, supplier_list: supplier_list, name: "Walnut Halves", price: price,
                                        in_stock: in_stock, supplier_product: sp)
      create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: supplier)
    end
    list
  end

  before { sign_in chef }

  def orderable_by_supplier(html, selector, id_attr)
    Nokogiri::HTML(html).css(selector).to_h { |cell| [cell[id_attr], cell["data-orderable"]] }
  end

  it "won't take an out-of-stock cell on desktop, except at US Foods, where out only warns" do
    get order_builder_aggregated_list_path(aggregated_list)

    cells = orderable_by_supplier(response.body, '[data-order-builder-target="supplierCell"]', "data-supplier-id-value")
    expect(cells).to eq(cw.id.to_s => "false", usf.id.to_s => "true", sysco.id.to_s => "true")
    expect(response.body).to include("Out of stock")
  end

  it "does the same on a phone" do
    get order_builder_aggregated_list_path(aggregated_list), headers: mobile_ua

    cells = orderable_by_supplier(response.body, '[data-mobile-order-builder-target="cell"]', "data-supplier-id")
    expect(cells).to eq(cw.id.to_s => "false", usf.id.to_s => "true", sysco.id.to_s => "true")
  end

  it "uses the same supplier rule as the review page" do
    expect(usf.out_of_stock_warns_only?).to be(true)
    expect(cw.out_of_stock_warns_only?).to be(false)
    expect(build(:supplier, scraper_class: nil, auth_type: "email").out_of_stock_warns_only?).to be(false)
  end
end
