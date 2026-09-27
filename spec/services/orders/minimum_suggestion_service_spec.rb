require "rails_helper"

# "Add these to reach the minimum" suggestions come partly from the order
# guide. For an owner with a separate login per restaurant (Performance), a
# D'oro order must draw on D'oro's guide, never another restaurant's.
RSpec.describe Orders::MinimumSuggestionService do
  let(:owner) { create(:user, :with_organization) }
  let(:org) { owner.current_organization }
  let(:alfios) { create(:location, organization: org, user: owner, name: "Alfios") }
  let(:doro) { create(:location, organization: org, user: owner, name: "D'oro") }
  let(:supplier) { create(:supplier) }

  # Perishable, so the cheapest-catalog fallback tier never picks them up.
  def guide_item(credential, name)
    sp = create(:supplier_product, supplier: supplier, current_price: 5.0,
                                   product: create(:product, name: name, category: "Produce"))
    list = SupplierList.find_or_create_by!(supplier: supplier, organization: org, location_id: credential.location_id,
                                           remote_list_id: "OG-#{credential.id}") do |l|
      l.supplier_credential = credential
      l.name = "Guide"
      l.list_type = "order_guide"
    end
    create(:supplier_list_item, supplier_list: list, supplier_product: sp, sku: "SKU-#{name}", name: name)
    sp
  end

  def suggestions_for(location)
    order = create(:order, user: owner, supplier: supplier, organization: org, location: location)
    described_class.new(user: owner, order: order).suggestions
  end

  it "suggests from D'oro's guide for a D'oro order, not the alfios guide" do
    alfios_login = create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id,
                                                location: alfios, status: "active")
    doro_login = create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id,
                                              location: doro, status: "active")
    alfios_item = guide_item(alfios_login, "Alfios arugula")
    doro_item = guide_item(doro_login, "Doro basil")

    ids = suggestions_for(doro).map(&:id)

    expect(ids).to include(doro_item.id)
    expect(ids).not_to include(alfios_item.id)
  end

  it "suggests what was recently ordered for D'oro, not for alfios" do
    create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id, location: doro, status: "active")
    ordered = lambda do |location, name|
      sp = create(:supplier_product, supplier: supplier, current_price: 5.0,
                                     product: create(:product, name: name, category: "Produce"))
      o = create(:order, user: owner, supplier: supplier, organization: org, location: location,
                         status: "submitted", submitted_at: 2.days.ago)
      create(:order_item, order: o, supplier_product: sp, quantity: 1, unit_price: 5)
      sp
    end
    for_alfios = ordered.call(alfios, "Alfios arugula")
    for_doro = ordered.call(doro, "Doro basil")

    ids = suggestions_for(doro).map(&:id)

    expect(ids).to include(for_doro.id)
    expect(ids).not_to include(for_alfios.id)
  end

  it "is unchanged for a user with one login for the supplier" do
    login = create(:supplier_credential, user: owner, supplier: supplier, organization_id: org.id,
                                         location: alfios, status: "active")
    item = guide_item(login, "Alfios arugula")

    expect(suggestions_for(alfios).map(&:id)).to include(item.id)
  end
end
