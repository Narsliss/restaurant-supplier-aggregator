require "rails_helper"

# Dark mode on the ordering screens (Safari audit, Oct 21 2026). Dark mode is a
# set of `.dark .<class>` overrides in application.css, so a colour that isn't
# one of those classes (inline style, an opacity variant like bg-brand-cream/95)
# silently stays light. These pin the three places that did.
RSpec.describe "Order builder dark mode", type: :request do
  let(:mobile_ua) { { "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" } }
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
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

  let(:stylesheet) { File.read(Rails.root.join("app/assets/tailwind/application.css")) }

  def dark_rule_for(selector)
    stylesheet[/\.dark #{Regexp.escape(selector)}[^{]*\{[^}]*\}/m]
  end

  before { sign_in chef }

  it "mutes the disabled Create Orders button instead of painting it a normal grey button" do
    get order_builder_aggregated_list_path(aggregated_list)
    buttons = Nokogiri::HTML(response.body).css("button[type=submit]").select { |b| b.text.include?("Create Orders") }

    expect(buttons).not_to be_empty
    buttons.each do |button|
      expect(button["disabled"]).not_to be_nil
      expect(button["class"].split).to include("bg-gray-300", "cursor-not-allowed")
    end
    rule = dark_rule_for(".bg-gray-300.cursor-not-allowed")
    expect(rule).to be_present
    expect(rule).to match(/\bcolor:\s*#6b7280/)
  end

  it "has a dark override for every translucent colour on the phone builder's sticky header" do
    get order_builder_aggregated_list_path(aggregated_list), headers: mobile_ua
    header = Nokogiri::HTML(response.body).at_css("header.sticky")

    translucent = header["class"].split.grep(%r{\A(bg|border)-[\w-]+/\d+\z})
    expect(translucent).to include("bg-brand-cream/95")
    translucent.each do |klass|
      expect(dark_rule_for(".#{klass.sub('/', '\\/')}")).to be_present, "no .dark override for #{klass}"
    end
  end

  it "builds the In this order panel's background from classes, not inline style" do
    js = File.read(Rails.root.join("app/javascript/controllers/order_builder_controller.js"))
    build = js[/_buildOrderPanel\(\) \{.*?document\.body\.appendChild\(this\._orderPanel\)/m]

    expect(build).to be_present
    expect(build).to include('className = "bg-white border-t border-gray-200"')
    expect(build).not_to match(/background\s*:/)
  end
end
