require "rails_helper"

# Nov 12 2026: a D'oro chef pressed one supplier card's orange "Submit Order"
# (US Foods) while Chef's Warehouse was still checking prices. CW and PPO stayed
# as drafts and he thought ordering was broken. Now:
# - Submit All is the primary action (top and bottom of the page); per-card
#   buttons are quiet "Submit only <supplier>" outlines that ask for a confirmation
#   when other orders are on the page.
# - Every submit button stays off while ANY order is still checking prices.
# - Submit All posts only the orders that are ready ("Submit 1 of 2" used to
#   post both).
# See docs/review-submit-all-primary.md.
RSpec.describe "Review page Submit All", type: :request do
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
  let!(:usf_credential) do
    create(:supplier_credential, user: chef, organization: organization, location: location, supplier: usf, status: "active")
  end
  let!(:cw_credential) do
    create(:supplier_credential, user: chef, organization: organization, location: location, supplier: cw, status: "active")
  end

  def order_for(supplier, verification_status: "verified")
    create(:order, user: chef, supplier: supplier, organization: organization, location: location,
                   batch_id: batch_id, status: "draft", verification_status: verification_status,
                   # fresh price check, so the review page doesn't re-verify it on load
                   price_verified_at: Time.current, delivery_date: Date.current + 1).tap do |o|
      product = create(:supplier_product, supplier: supplier, supplier_name: "#{supplier.name} item")
      # Above every supplier minimum (USF $250, CW $400 in the scraper constants).
      create(:order_item, order: o, supplier_product: product, quantity: 1, unit_price: 600)
    end
  end

  before { sign_in chef }

  def page_html
    get review_orders_path(batch_id: batch_id)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def submit_all_buttons(doc)
    doc.css("button[data-order-review-target='submitAllBtn']")
  end

  def card_buttons(doc)
    doc.css("button[data-order-review-target='supplierSubmitBtn']")
  end

  def posted_order_ids(button)
    query = URI.parse(button.ancestors("form").first["action"]).query.to_s
    Rack::Utils.parse_nested_query(query)["order_ids"].to_a
  end

  context "while one order is still checking prices" do
    let!(:usf_order) { order_for(usf) }
    let!(:cw_order) { order_for(cw, verification_status: "verifying") }

    it "keeps Submit All off and says why" do
      submit_all_buttons(page_html).each do |button|
        expect(button.text.strip).to eq("Checking prices…")
        expect(button["disabled"]).to be_present
      end
    end

    it "keeps every card's button off too, including the order that is ready" do
      buttons = card_buttons(page_html)
      expect(buttons.size).to eq(2)
      buttons.each do |button|
        expect(button.text.strip).to eq("Waiting for prices…")
        expect(button["disabled"]).to be_present
      end
    end
  end

  context "when checks are done but one order can't be sent" do
    let!(:usf_order) { order_for(usf) }
    # A failed check counts as done, so it can't lock the page.
    let!(:cw_order) { order_for(cw, verification_status: "failed") }

    it "renders Submit All at the top and the bottom of the page" do
      expect(submit_all_buttons(page_html).size).to eq(2)
    end

    it "posts only the ready order (regression: Submit 1 of 2 used to post both)" do
      submit_all_buttons(page_html).each do |button|
        expect(button.text.strip).to eq("Submit 1 of 2 Orders")
        expect(button["disabled"]).to be_nil
        expect(posted_order_ids(button)).to eq([usf_order.id.to_s])
      end
    end

    it "makes Submit All the orange button and the per-card buttons quiet outlines" do
      doc = page_html
      submit_all_buttons(doc).each { |b| expect(b["class"]).to include("bg-brand-orange") }

      expect(card_buttons(doc).map { |b| b.text.strip })
        .to contain_exactly("Submit only US Foods", "Submit only Chef's Warehouse")
      card_buttons(doc).each do |button|
        expect(button["class"]).not_to include("bg-brand-orange")
        expect(button["class"]).to include("border-gray-300")
      end
    end

    it "asks before submitting a single supplier" do
      doc = page_html

      card_buttons(doc).each do |button|
        form = button.ancestors("form").first
        expect(form["data-action"]).to eq("submit->order-review#interceptSingleSubmit")
        expect(posted_order_ids(button)).to eq([button["data-order-id"]])
      end

      modal = doc.at_css("[data-order-review-target='singleSubmitModal']")
      expect(modal).to be_present
      expect(modal["role"]).to eq("dialog")
      expect(modal.text).to include("These orders won't be sent. They'll stay as drafts")
      expect(modal.at_css("[data-action='order-review#submitAllFromDialog']")).to be_present
      expect(modal.at_css("[data-action='order-review#confirmSingleSubmit']")).to be_present
    end
  end

  context "with every order ready" do
    let!(:usf_order) { order_for(usf) }
    let!(:cw_order) { order_for(cw) }

    it "offers Submit All Orders and posts both" do
      submit_all_buttons(page_html).each do |button|
        expect(button.text.strip).to eq("Submit All Orders")
        expect(button["disabled"]).to be_nil
        expect(posted_order_ids(button)).to contain_exactly(usf_order.id.to_s, cw_order.id.to_s)
      end
    end

    it "enables each card's button" do
      card_buttons(page_html).each { |b| expect(b["disabled"]).to be_nil }
    end
  end
end
