require "rails_helper"

# Safari-only fixes (Safari audit, Oct 21 2026; Carmin: "make sure the blast
# radius on this is confined completely to safari"). The ordering-path date
# fields get a `safari-date` hook that only acts in Safari's engine, and the
# owner's phone restaurant picker gets a class that is only styled inside a
# WebKit-only @supports block. Other browsers render exactly what they did.
RSpec.describe "Safari-only date and picker fixes", type: :request do
  let(:mobile_ua) { { "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" } }
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:chef) do
    user = create(:user, current_organization: organization)
    create(:membership, user: user, organization: organization, role: "chef", active: true).membership_locations.create!(location: location)
    create(:subscription, user: user, organization_id: organization.id)
    user
  end
  let(:supplier) { create(:supplier) }

  def html = Nokogiri::HTML(response.body)

  describe "ordering-path date fields carry the Safari hook" do
    before do
      create(:supplier_credential, user: chef, organization: organization, location: location, supplier: supplier, status: "active")
      sign_in chef
      post switch_location_path, params: { location_id: location.id }
    end

    it "on the order builder's bottom bar (both layouts)" do
      list = create(:aggregated_list, organization: organization, location_id: location.id)
      supplier_list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
      list.aggregated_list_mappings.find_or_create_by!(supplier_list: supplier_list)
      sli = create(:supplier_list_item, supplier_list: supplier_list, name: "Chicken Breast", price: 68.90,
                                        supplier_product: create(:supplier_product, supplier: supplier, current_price: 68.90, in_stock: true))
      create(:product_match_item, product_match: create(:product_match, aggregated_list: list, canonical_name: "Chicken Breast"),
                                  supplier_list_item: sli, supplier: supplier)

      get order_builder_aggregated_list_path(list)
      inputs = html.css("input[type=date][name=delivery_date]")

      expect(inputs.size).to eq(2)
      inputs.each do |input|
        expect(input["data-controller"]).to eq("safari-date")
        expect(input["data-order-builder-target"]).to eq("deliveryDate")
        expect(input["required"]).not_to be_nil
      end
    end

    it "on the review page, keeping its change handler" do
      create(:order, user: chef, supplier: supplier, organization: organization, location: location, status: "draft",
                     batch_id: "batch-1", delivery_date: nil, verification_status: "verified", price_verified_at: Time.current)

      get review_orders_path(batch_id: "batch-1")
      input = html.at_css("input[type=date][data-order-review-target=deliveryDate]")

      expect(input["data-controller"]).to eq("safari-date")
      expect(input["data-action"]).to eq("change->order-review#updateDeliveryDate")
    end

    it "on a pending order's page, keeping its change handler" do
      order = create(:order, user: chef, supplier: supplier, organization: organization, location: location, status: "pending")

      get order_path(order)
      input = html.at_css("input[type=date][data-order-edit-target=deliveryDate]")

      expect(input["data-controller"]).to eq("safari-date")
      expect(input["data-action"]).to eq("change->order-edit#updateDeliveryDate")
    end
  end

  it "tags the owner's phone restaurant picker for the Safari-only style" do
    create(:location, organization: organization)
    owner = create(:user, current_organization: organization)
    create(:membership, user: owner, organization: organization, role: "owner", active: true)
    create(:subscription, user: owner, organization_id: organization.id)
    chef # a second active member, so the owner is past onboarding
    sign_in owner

    get root_path, headers: mobile_ua
    picker = html.at_css('select[data-action="change->location-selector#change"]')

    expect(picker["class"].split).to include("safari-select-card")
  end

  describe "nothing applies outside Safari's engine" do
    it "styles the picker class only inside a WebKit-only @supports block" do
      css = File.read(Rails.root.join("app/assets/tailwind/application.css"))
      outside = css.gsub(/@supports \(font: -apple-system-body\) \{.*?\n\}\n/m, "")

      expect(css).to match(/@supports \(font: -apple-system-body\) \{\s*select\.safari-select-card \{/)
      expect(outside).not_to include("safari-select-card")
    end

    it "returns before touching the page unless the browser is Safari's engine" do
      js = File.read(Rails.root.join("app/javascript/controllers/safari_date_controller.js"))

      expect(js).to include('return navigator.vendor === "Apple Computer, Inc."')
      expect(js[/connect\(\) \{\s*\n\s*(.+)/, 1]).to eq("if (!isSafariEngine()) return")
    end

    it "leaves the phone calendar's behaviour unchanged for its existing callers" do
      js = File.read(Rails.root.join("app/javascript/controllers/mobile_calendar.js"))

      expect(js).to include("export function openCalendar(selectedIso, onPick, opts = {})")
      expect(js).to include("maxIso: opts.maxIso || null")
      expect(js).to match(/if \(opts\.narrow\)/)
    end
  end
end
