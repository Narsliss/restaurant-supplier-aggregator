require 'rails_helper'

# Sep 15 2026: a routine guide refresh deleted supplier list items that chefs had
# matched and confirmed, and the delete cascaded (in Rails and in the database)
# to their matched rows. A chef's matching is hours of work. The rule now: a
# supplier list item a matched row uses cannot be deleted, full stop. The one
# deliberate way a supplier leaves matched rows is removing that supplier
# connection (or the supplier) — and every removal leaves a record.
RSpec.describe 'Protecting chefs\' matched rows' do
  let(:user) { create(:user, :with_organization) }
  let(:org) { user.current_organization }
  let(:location) { create(:location, organization: org, user: user) }
  let(:aggregated_list) { create(:aggregated_list, organization: org, location_id: location.id) }
  let(:usf) { create(:supplier, name: 'Guard USF') }
  let(:cw) { create(:supplier, name: 'Guard CW') }
  let(:usf_credential) { create(:supplier_credential, supplier: usf, user: user, organization_id: org.id, location_id: location.id) }
  let(:cw_credential) { create(:supplier_credential, supplier: cw, user: user, organization_id: org.id, location_id: location.id) }
  let(:usf_list) { create(:supplier_list, supplier: usf, supplier_credential: usf_credential, organization: org, location: location) }
  let(:cw_list) { create(:supplier_list, supplier: cw, supplier_credential: cw_credential, organization: org, location: location) }

  def item_on(list, name)
    create(:supplier_list_item, supplier_list: list, name: name,
                                supplier_product: create(:supplier_product, supplier: list.supplier))
  end

  def row_with(*items, status: 'confirmed', name: 'Mozzarella Curd')
    row = create(:product_match, aggregated_list: aggregated_list, match_status: status, canonical_name: name)
    items.each { |sli| create(:product_match_item, product_match: row, supplier_list_item: sli) }
    row
  end

  describe 'a list item a matched row uses' do
    it 'cannot be deleted, and the chef keeps the match' do
      sli = item_on(usf_list, 'USF Mozzarella')
      row = row_with(sli)

      expect { sli.destroy! }.to raise_error(ActiveRecord::DeleteRestrictionError)
      expect(row.reload.product_match_items.count).to eq(1)
    end

    it 'is protected in machine-matched rows too, not only confirmed ones' do
      sli = item_on(usf_list, 'USF Mozzarella')
      row = row_with(sli, status: 'auto_matched')

      expect { sli.destroy }.to raise_error(ActiveRecord::DeleteRestrictionError)
      expect(row.reload.product_match_items.count).to eq(1)
    end

    it 'is refused by the database even when Rails callbacks are skipped' do
      sli = item_on(usf_list, 'USF Mozzarella')
      row_with(sli)

      expect { SupplierListItem.where(id: sli.id).delete_all }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it 'survives a failed supplier login' do
      sli = item_on(usf_list, 'USF Mozzarella')
      row = row_with(sli)

      usf_credential.update!(status: 'hold')
      usf_credential.update!(status: 'expired')

      expect(row.reload.product_match_items.count).to eq(1)
      expect(SupplierListItem.exists?(sli.id)).to be(true)
    end
  end

  it 'still deletes a list item no row uses' do
    sli = item_on(usf_list, 'Unmatched thing')

    expect { sli.destroy! }.not_to raise_error
  end

  describe 'removing a supplier connection (a deliberate decision)' do
    it "takes that supplier's items out of matched rows and leaves other suppliers alone" do
      usf_item = item_on(usf_list, 'USF Mozzarella')
      cw_item = item_on(cw_list, 'CW Mozzarella')
      row = row_with(usf_item, cw_item)

      usf_credential.destroy!

      expect(row.reload.product_match_items.map(&:supplier_id)).to eq([cw.id])
      expect(SupplierList.exists?(usf_list.id)).to be(false)
    end

    it 'records each removal with what did it and who' do
      usf_item = item_on(usf_list, 'USF Mozzarella')
      row = row_with(usf_item, item_on(cw_list, 'CW Mozzarella'))

      MatchChange.set(user: user) { usf_credential.destroy! }

      removal = MatchItemRemoval.find_by!(product_match_id: row.id)
      expect(removal).to have_attributes(cause: 'supplier_connection_removed', supplier_id: usf.id,
                                         item_name: 'USF Mozzarella', row_status: 'confirmed',
                                         aggregated_list_id: aggregated_list.id, user_id: user.id)
    end

    it 'deletes rows it leaves empty, so no all-"No match" row is left behind' do
      row = row_with(item_on(usf_list, 'USF only item'))

      usf_credential.destroy!

      expect(ProductMatch.exists?(row.id)).to be(false)
    end

    it "keeps an emptied row a chef's order list still points at" do
      row = row_with(item_on(usf_list, 'USF only item'))
      order_list = OrderList.create!(user: user, name: 'Weekly', location: location, organization_id: org.id)
      entry = OrderListItem.create!(order_list: order_list, product_match: row)

      usf_credential.destroy!

      expect(ProductMatch.exists?(row.id)).to be(true)
      expect(entry.reload.product_match_id).to eq(row.id)
    end
  end

  it 'lets a supplier be deleted, taking it out of matched rows' do
    usf_item = item_on(usf_list, 'USF Mozzarella')
    row = row_with(usf_item, item_on(cw_list, 'CW Mozzarella'))

    usf.destroy!

    expect(row.reload.product_match_items.map(&:supplier_id)).to eq([cw.id])
    expect(MatchItemRemoval.where(product_match_id: row.id).pluck(:cause)).to eq(['supplier_deleted'])
  end

  it 'lets an organization be deleted completely' do
    row_with(item_on(usf_list, 'USF Mozzarella'), item_on(cw_list, 'CW Mozzarella'))
    # Same preparation as Dev::CompanySandbox#teardown (see reference_org_destroy_order).
    org.organization_invitations.destroy_all
    User.where(current_organization_id: org.id).update_all(current_organization_id: nil)

    expect { org.destroy! }.not_to raise_error
    expect(SupplierListItem.where(supplier_list_id: [usf_list.id, cw_list.id])).to be_empty
    expect(MatchItemRemoval.count).to eq(0)
  end

  it "records a chef's own edit as chef_edit" do
    usf_item = item_on(usf_list, 'USF Mozzarella')
    row = row_with(usf_item, item_on(cw_list, 'CW Mozzarella'))

    MatchChange.as('chef_edit') { row.product_match_items.find_by!(supplier_id: usf.id).destroy! }

    expect(MatchItemRemoval.last).to have_attributes(cause: 'chef_edit', supplier_list_item_id: usf_item.id,
                                                     sku: usf_item.sku, row_name: 'Mozzarella Curd')
  end

  it 'records a whole row going as row_deleted' do
    row = row_with(item_on(usf_list, 'USF Mozzarella'))

    row.destroy!

    expect(MatchItemRemoval.where(product_match_id: row.id).pluck(:cause)).to eq(['row_deleted'])
  end
end
