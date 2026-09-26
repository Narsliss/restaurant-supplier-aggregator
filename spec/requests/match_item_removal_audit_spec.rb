require 'rails_helper'

# Every item that leaves a matched row leaves a record of what did it and who,
# so a chef's lost matching work can always be rebuilt (see MatchItemRemoval).
RSpec.describe 'Recording removals from matched rows', type: :request do
  let(:owner) { create(:user, :fully_onboarded) }
  let(:org) { owner.current_organization }
  let(:location) { org.locations.first }
  let(:aggregated_list) { AggregatedList.find_by!(organization: org, location_id: location.id, list_type: 'matched') }
  let(:supplier_a) { create(:supplier, name: 'Audit A') }
  let(:supplier_b) { create(:supplier, name: 'Audit B') }
  let(:row) { create(:product_match, aggregated_list: aggregated_list, match_status: 'confirmed', canonical_name: 'Burrata') }

  def item(supplier)
    list = create(:supplier_list, supplier: supplier, organization: org, location: location)
    sli = create(:supplier_list_item, supplier_list: list, name: "#{supplier.name} Burrata")
    create(:product_match_item, product_match: row, supplier_list_item: sli)
  end

  before { sign_in owner }

  it "records a chef choosing 'No match' in the matching popup as their own edit" do
    removed = item(supplier_a)
    item(supplier_b)

    patch product_match_item_path(removed), params: { product_match_item: { supplier_list_item_id: '' } }

    expect(MatchItemRemoval.last).to have_attributes(cause: 'chef_edit', user_id: owner.id,
                                                     product_match_id: row.id, supplier_id: supplier_a.id,
                                                     item_name: 'Audit A Burrata', row_status: 'confirmed')
  end
end
