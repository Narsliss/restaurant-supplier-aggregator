require 'rails_helper'

# The Best Deals table took a raw MAX(current_price) over anything sharing a
# Product id -- no unit conversion, no check that the two packs held the same
# amount. It set a 5 lb bag of peeled garlic against a 20 lb case FROM THE SAME
# SUPPLIER and called the $495 difference a saving.
RSpec.describe "Best Deals accuracy", type: :request do
  let(:org) { create(:organization) }
  let(:location) { create(:location, organization: org) }
  let(:chef) do
    user = create(:user, current_organization: org)
    membership = create(:membership, user: user, organization: org, role: "owner", active: true)
    membership.membership_locations.create!(location: location)
    user
  end
  let!(:subscription) { create(:subscription, user: chef, organization_id: org.id) }
  let!(:teammate) { create(:membership, user: create(:user), organization: org, role: "chef", active: true) }
  let!(:credential) do
    create(:supplier_credential, user: chef, organization: org, location: location,
                                 supplier: ppo, status: "active")
  end
  let(:product) { Product.create!(name: "Peeled Garlic") }

  def supplier(name)
    Supplier.find_or_create_by!(code: name.parameterize) do |s|
      s.name = name
      s.base_url = "https://example.test"
      s.login_url = "https://example.test/login"
      s.scraper_class = "Scrapers::BaseScraper"
    end
  end

  def catalog(sup, name:, pack:, price:)
    SupplierProduct.create!(supplier: sup, supplier_sku: "#{name}-#{pack}-#{price}".parameterize,
                            supplier_name: name, pack_size: pack, current_price: price,
                            product: product)
  end

  def bought(sp, unit_price:, quantity: 1)
    order = Order.create!(organization: org, user: chef, supplier: sp.supplier,
                          location: location, status: "submitted")
    order.order_items.create!(supplier_product: sp, quantity: quantity, unit_price: unit_price,
                              line_total: unit_price * quantity, product_name: sp.supplier_name)
    order
  end

  before { sign_in chef }

  let(:ppo) { supplier("Deals Produce") }
  let(:usf) { supplier("Deals Foods") }

  it "never compares a small bag against a case several times its size" do
    small = catalog(ppo, name: "PEELED GARLIC", pack: "1/5 LB", price: 20.85)
    catalog(ppo, name: "PEELED GARLIC BULK", pack: "4/5 LB", price: 91.55)
    bought(small, unit_price: 20.85, quantity: 7)

    get savings_reports_path
    expect(response).to have_http_status(:ok)

    # The old query took MAX(current_price) = $91.55 for a 20 lb case and set it
    # against a 5 lb bag: (91.55 - 20.85) x 7 = $494.90 of pure pack difference.
    expect(response.body).not_to include("$494.90")
  end

  it "never treats the supplier you bought from as your own alternative" do
    small = catalog(ppo, name: "PEELED GARLIC", pack: "1/5 LB", price: 20.85)
    catalog(ppo, name: "PEELED GARLIC OTHER", pack: "1/5 LB", price: 99.00)
    bought(small, unit_price: 20.85, quantity: 2)

    get savings_reports_path
    expect(response).to have_http_status(:ok)
    # (99.00 - 20.85) x 2 = $156.30, all of it from the chefs own supplier.
    expect(response.body).not_to include("$156.30")
  end

  it "compares against a real alternative in a comparable pack" do
    small = catalog(ppo, name: "PEELED GARLIC", pack: "1/5 LB", price: 20.85)
    catalog(usf, name: "GARLIC PEELED", pack: "1/5 LB", price: 28.23)
    bought(small, unit_price: 20.85, quantity: 2)

    get savings_reports_path
    expect(response).to have_http_status(:ok)
    # (28.23 - 20.85) x 2 = 14.76
    expect(response.body).to include("$14.76")
  end
end
