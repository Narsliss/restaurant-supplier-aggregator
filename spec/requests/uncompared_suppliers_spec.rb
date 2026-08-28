require "rails_helper"

# A line where two suppliers share a unit reads as :exact and earns a BEST, even
# when a third supplier could not be ranked at all. The cell said "Not compared"
# and the row said nothing, so on a pass down the list the only way to find it
# was opening every line — and what hides there is not always a unit problem.
# A hot dog bun matched to a case of paper cups lands in exactly the same place.
RSpec.describe "Suppliers left out of a clean comparison", type: :request do
  let(:organization) { create(:organization) }
  let(:location) { create(:location, organization: organization) }
  let(:aggregated_list) { create(:aggregated_list, organization: organization, location_id: location.id) }

  let(:chef) do
    user = create(:user, current_organization: organization)
    m = create(:membership, user: user, organization: organization, role: "chef", active: true)
    m.membership_locations.create!(location: location)
    create(:subscription, user: user, organization_id: organization.id)
    create(:supplier_credential, user: user, organization: organization, location: location,
                                 supplier: Supplier.first || create(:supplier), status: "active")
    user
  end

  let(:match) { create(:product_match, aggregated_list: aggregated_list, canonical_name: "Brioche Bun") }

  def line(supplier_name, pack_size, price)
    supplier = create(:supplier, name: supplier_name)
    list = create(:supplier_list, supplier: supplier, organization: organization, location: location)
    aggregated_list.aggregated_list_mappings.find_or_create_by!(supplier_list: list)
    sli = create(:supplier_list_item, supplier_list: list, name: "Bun", pack_size: pack_size, price: price,
                                      supplier_product: create(:supplier_product, supplier: supplier,
                                                               pack_size: pack_size, current_price: price,
                                                               in_stock: true))
    create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: supplier)
    supplier
  end

  before { sign_in chef }

  context "when two suppliers rank and a third cannot" do
    before do
      line("Chef's Warehouse", "80x2.5 Oz Case", 76.78)
      line("US Foods", "8/6/2.3 OZ", 50.17)
      @odd = line("Premiere Produce One", "CASE - 1-96 CT", 56.10)
    end

    it "still awards BEST, because the ranked pair really did match" do
      expect(match.comparison_verdict).to eq(:exact)
    end

    it "names the supplier that never competed" do
      expect(match.uncompared_price_rows.map { |p| p[:supplier] }).to eq([@odd])
    end

    it "stops the pill claiming a best price it cannot know" do
      get aggregated_list_path(aggregated_list)

      card = Nokogiri::HTML(response.body).at_css("##{ActionView::RecordIdentifier.dom_id(match)}")
      # "BEST" reads as best price. It is the best of the two that could be
      # ranked, and the pill has to say which.
      expect(card.text).to include("BEST of 2")
      expect(card.css("span").map { |n| n.text.strip }).not_to include("BEST")
    end

    it "says so on the row, not only inside the odd cell" do
      get aggregated_list_path(aggregated_list)

      card = Nokogiri::HTML(response.body).at_css("##{ActionView::RecordIdentifier.dom_id(match)}")
      expect(card.text).to include("1 not compared")
      # Not the clash badge: the two suppliers that were ranked matched fine.
      expect(card.text).not_to include("Units don't match")
    end
  end

  context "when everyone ranks" do
    before do
      line("Chef's Warehouse", "80x2.5 Oz Case", 76.78)
      line("US Foods", "8/6/2.3 OZ", 50.17)
    end

    it "stays quiet" do
      expect(match.uncompared_price_rows).to be_empty

      get aggregated_list_path(aggregated_list)
      card = Nokogiri::HTML(response.body).at_css("##{ActionView::RecordIdentifier.dom_id(match)}")
      expect(card.text).not_to include("not compared")
    end
  end
end
