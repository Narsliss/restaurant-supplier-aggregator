require "rails_helper"

# When suppliers on a line price in different units there is no honest cheapest,
# so the order builder must not claim one. It previously did: `is_default` had no
# comparability test, so the lowest CASE TOTAL supplier was pre-selected, ringed
# in brand green and given the BEST pill — on exactly the lines the matched-list
# page flags amber and refuses to rank.
#
# The pre-selection itself stays. Removing it does not disable the + button, it
# drops `_primarySupplier` through to whichever cell renders first, which is a
# weaker basis still (column order). So: keep the selection, drop the verdict.
#
# Each product renders twice per page (desktop card + in-page mobile card), so
# assertions count both copies.
RSpec.describe "Order builder with clashing units", type: :request do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:chef) do
    user = create(:user, current_organization: organization)
    membership = create(:membership, user: user, organization: organization, role: "chef", active: true)
    membership.membership_locations.create!(location: location)
    user
  end
  let(:supplier_a) { create(:supplier, name: "Premiere Produce One") }
  let(:supplier_b) { create(:supplier, name: "What Chefs Want") }
  let!(:subscription) { create(:subscription, user: chef, organization_id: organization.id) }

  # packs: [[supplier, price, pack_size], ...]
  def build_list(packs, product_name: "Green Bell Peppers")
    list = create(:aggregated_list, organization: organization, location_id: location.id)
    match = create(:product_match, aggregated_list: list, canonical_name: product_name)

    packs.each do |supplier, price, pack_size|
      create(:supplier_credential, user: chef, organization: organization, location: location,
                                   supplier: supplier, status: "active")
      supplier_list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
      list.aggregated_list_mappings.find_or_create_by!(supplier_list: supplier_list)
      sli = create(:supplier_list_item, supplier_list: supplier_list, name: product_name,
                                        price: price, pack_size: pack_size,
                                        supplier_product: create(:supplier_product, supplier: supplier,
                                                                 current_price: price, pack_size: pack_size,
                                                                 in_stock: true))
      create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: supplier)
    end
    [list, match]
  end

  def get_builder(list)
    sign_in chef
    get order_builder_aggregated_list_path(list)
  end

  def doc
    Nokogiri::HTML(response.body)
  end

  def visible_best_pills
    doc.css("[data-best-badge]").reject { |n| n["class"].to_s.split(/\s+/).include?("hidden") }
  end

  def preselected_cells
    doc.css('[data-order-builder-target="supplierCell"][data-default="true"]')
  end

  context "when both suppliers quote a comparable pack" do
    before do
      list, = build_list([[supplier_a, 32.00, "10 LB"], [supplier_b, 41.00, "10 LB"]])
      get_builder(list)
    end

    it "ranks them and shows BEST" do
      expect(response).to have_http_status(:ok)
      expect(visible_best_pills).not_to be_empty
      expect(response.body).to include("compared by per-unit price")
    end
  end

  context "when the suppliers price in different units" do
    before do
      # Deliberately NOT produce: a bushel of peppers against a count of
      # peppers IS comparable, because ProduceWeightEstimator knows bell
      # peppers and converts both to $/oz. Puff pastry is the real clash —
      # "SHEET" is not a unit UnitParser knows and no estimator covers it.
      list, @match = build_list([[supplier_a, 32.00, "10 SHEET"], [supplier_b, 41.00, "12 LB"]],
                                product_name: "Puff Pastry Dough")
      get_builder(list)
    end

    it "is genuinely incomparable, not merely untested" do
      expect(@match.reload.per_unit_comparable?).to be(false)
    end

    it "withholds the BEST pill entirely" do
      expect(response).to have_http_status(:ok)
      expect(visible_best_pills).to be_empty
    end

    it "says why instead of claiming a winner" do
      expect(response.body).to include("lowest price &middot; packs differ").or include("lowest price · packs differ")
      expect(response.body).not_to include("compared by per-unit price")
    end

    # The regression that matters: the line must still be orderable, and the
    # + button routes to whichever cell is marked default.
    it "still pre-selects a supplier so the line can be ordered" do
      expect(preselected_cells).not_to be_empty
    end
  end
end
