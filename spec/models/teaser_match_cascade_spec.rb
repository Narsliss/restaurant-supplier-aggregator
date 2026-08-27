require 'rails_helper'

# Regression: teaser_matches FKs both aggregated_lists and product_matches with
# no ON DELETE, and neither model declared the association. Every path that
# destroys a match or a list raised PG::ForeignKeyViolation as soon as the list
# had teasers — which is any list whose org still has an unconnected supplier,
# since TeaserCatalogSearchService only builds cells for those.
RSpec.describe 'Destroying matches and lists that carry teaser rows' do
  let(:user) { create(:user) }
  let(:org) { create(:organization) }
  let(:location) { create(:location, user: user, organization: org) }
  let(:supplier) { create(:supplier) }
  let(:aggregated_list) do
    create(:aggregated_list, organization: org, created_by: user, location_id: location.id)
  end
  let(:product_match) { create(:product_match, aggregated_list: aggregated_list) }

  def add_teaser(match)
    TeaserMatch.create!(
      aggregated_list: match.aggregated_list, product_match: match, supplier: supplier,
      supplier_product: create(:supplier_product, supplier: supplier), confidence_score: 0.8
    )
  end

  # product_match_items_controller: removing a match's last supplier item
  it 'destroys a single match and takes its teasers with it' do
    add_teaser(product_match)

    expect { product_match.destroy! }.to change(TeaserMatch, :count).by(-1)
    expect(ProductMatch.exists?(product_match.id)).to be(false)
  end

  # AiProductMatcherService: re-running matching wipes and rebuilds the matches
  it 'wipes every match on a re-match' do
    add_teaser(product_match)
    add_teaser(create(:product_match, aggregated_list: aggregated_list))

    expect { aggregated_list.product_matches.destroy_all }
      .to change(TeaserMatch, :count).by(-2)
    expect(aggregated_list.product_matches.reload).to be_empty
  end

  # aggregated_lists_controller#destroy: the chef deletes the matched list
  it 'destroys the list along with its teasers and the working order' do
    add_teaser(product_match)
    CurrentOrder.create!(
      user: user, aggregated_list: aggregated_list,
      state: { product_match.id.to_s => [{ 'supplierId' => supplier.id.to_s, 'qty' => 2, 'uom' => 'CS' }] }
    )

    expect { aggregated_list.destroy! }
      .to change(TeaserMatch, :count).by(-1)
      .and change(CurrentOrder, :count).by(-1)

    expect(AggregatedList.exists?(aggregated_list.id)).to be(false)
  end

  # The cascade must not reach the ordering tables. orders/order_items hold no
  # FK to matched lists at all; order_list_items points at product_matches with
  # on_delete: :nullify, so a chef's ordering list survives the match going away.
  describe 'ordering data' do
    it 'leaves placed orders untouched' do
      order = create(:order, organization: org, user: user, supplier: supplier)
      add_teaser(product_match)

      aggregated_list.destroy!

      expect(Order.exists?(order.id)).to be(true)
    end

    it 'keeps order-list rows, only clearing their match pointer' do
      order_list = OrderList.create!(user: user, organization: org, location: location, name: 'Weekly')
      item = OrderListItem.create!(order_list: order_list, product_match_id: product_match.id, quantity: 3)
      add_teaser(product_match)

      product_match.destroy!

      expect(OrderListItem.exists?(item.id)).to be(true)
      expect(item.reload.product_match_id).to be_nil
      expect(item.quantity).to eq(3)
    end
  end
end
