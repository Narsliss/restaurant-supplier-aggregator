require "rails_helper"

# Carmin, Oct 19 2026 (plan D1): an item out of stock at US Foods at the price
# check is WARNED — the chef can remove it, or place the order and US Foods
# fills or shorts it. Other suppliers keep the existing rule: Submit stays off
# until the item is removed. Discontinued items always block.
RSpec.describe "Review page out-of-stock warning", type: :request do
  MOBILE = { "HTTP_USER_AGENT" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)" }.freeze

  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:chef) do
    user = create(:user, current_organization: organization)
    membership = create(:membership, user: user, organization: organization, role: "chef", active: true)
    membership.membership_locations.create!(location: location)
    user
  end
  let!(:subscription) { create(:subscription, user: chef, organization_id: organization.id) }
  let(:batch_id) { SecureRandom.uuid }

  let(:usf) { create(:supplier, name: "US Foods", scraper_class: "Scrapers::UsFoodsScraper") }
  let(:cw) { create(:supplier, name: "Chef's Warehouse", scraper_class: "Scrapers::ChefsWarehouseScraper") }
  # Chefs must have a connected supplier to get past onboarding.
  let!(:credential) do
    create(:supplier_credential, user: chef, organization: organization, location: location, supplier: usf, status: "active")
  end

  def order_with(supplier, product)
    create(:order, user: chef, supplier: supplier, organization: organization, location: location,
                   batch_id: batch_id, status: "pending", verification_status: "verified").tap do |o|
      create(:order_item, order: o, supplier_product: product, quantity: 1, unit_price: 50)
    end
  end

  before { sign_in chef }

  context "US Foods item out of stock" do
    let(:walnuts) { create(:supplier_product, supplier: usf, supplier_name: "Walnut Halves", in_stock: false) }
    let!(:order) { order_with(usf, walnuts) }

    it "warns on desktop without disabling Submit for it" do
      get review_orders_path(batch_id: batch_id)

      expect(response.body).to include("Out of stock — may be shorted")
      expect(response.body).to include('data-stock-warning="true"')
      expect(response.body).not_to include('data-in-stock="false"')
    end

    it "warns on mobile, with how to remove it" do
      get review_orders_path(batch_id: batch_id), headers: MOBILE

      expect(response.body).to include("Out of stock at US Foods right now")
    end

    it "marks it non-blocking in the poll" do
      get verification_status_orders_path(batch_id: batch_id), as: :json

      item = JSON.parse(response.body)["orders"].first["unavailable_items"].first
      expect(item).to include("name" => "Walnut Halves", "blocking" => false)
    end

    it "still blocks when the item is discontinued" do
      walnuts.update!(discontinued: true)

      get verification_status_orders_path(batch_id: batch_id), as: :json

      expect(JSON.parse(response.body)["orders"].first["unavailable_items"].first["blocking"]).to be(true)
    end
  end

  context "another supplier's item out of stock" do
    let(:cheese) { create(:supplier_product, supplier: cw, supplier_name: "Mascarpone", in_stock: false) }
    let!(:order) { order_with(cw, cheese) }

    it "keeps blocking Submit until it is removed" do
      get review_orders_path(batch_id: batch_id)

      expect(response.body).to include('data-in-stock="false"')
      expect(response.body).not_to include("may be shorted")
    end

    # Plan 3.3 (Carmin, Oct 19: block). The phone blocks only on today's
    # readings; an old flag with no reading today stays quiet, as before.
    it "shows nothing on mobile for an old flag with no reading today" do
      cheese.update!(stock_checked_at: 1.day.ago)

      get review_orders_path(batch_id: batch_id), headers: MOBILE

      expect(response.body).not_to include("Out of stock at")
      expect(response.body).to include('data-stock-blocked="false"')
    end

    it "blocks Place on mobile when the supplier said it is out today, and says how to fix it" do
      cheese.update!(stock_checked_at: 10.minutes.ago, stock_source: "price_check")

      get review_orders_path(batch_id: batch_id), headers: MOBILE

      expect(response.body).to include("Out of stock at Chef&#39;s Warehouse right now, so they won't take it")
      expect(response.body).to include("data-stock-blocking=true", 'data-stock-blocked="true"')
      expect(response.body).to include("Remove the items marked out of stock to place.")
    end

    it "lets Place go once the item is in stock again" do
      cheese.update!(in_stock: true, stock_checked_at: 10.minutes.ago)

      get review_orders_path(batch_id: batch_id), headers: MOBILE

      expect(response.body).to include('data-stock-blocked="false"')
      expect(response.body).not_to include("Out of stock at")
    end
  end
end
