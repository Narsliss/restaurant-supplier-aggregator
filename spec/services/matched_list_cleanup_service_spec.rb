require 'rails_helper'

RSpec.describe MatchedListCleanupService do
  # Models the alfios incident: rotated USF guides left duplicate lines
  # (distinct SP rows, same spine product), catalog-search paired them
  # identically, rejections left zero-item husks.
  let(:org) { create(:organization) }
  let(:user) { create(:user) }
  let(:location) { create(:location, organization: org, user: user) }
  let(:aggregated_list) do
    create(:aggregated_list, organization: org, created_by: user, location_id: location.id)
  end
  let(:usf) { create(:supplier, name: 'US Foods') }
  let(:usf_list) { create(:supplier_list, supplier: usf, organization: org, location: location) }
  let(:spine) { Product.create!(name: 'Beef Tenderloin') }
  let(:service) { described_class.new(aggregated_list) }

  def line(status:, sp:, sku:)
    sli = create(:supplier_list_item, supplier_list: usf_list, sku: sku, supplier_product: sp)
    pm = create(:product_match, aggregated_list: aggregated_list, match_status: status)
    create(:product_match_item, product_match: pm, supplier_list_item: sli)
    pm
  end

  describe '#scan' do
    it 'flags machine lines sharing a spine product, keeping chef lines as keepers' do
      sp_old = create(:supplier_product, supplier: usf, supplier_sku: 'U1', product: spine)
      sp_new = create(:supplier_product, supplier: usf, supplier_sku: 'U1B', product: spine)

      chef_line = line(status: 'manual', sp: sp_old, sku: 'U1')
      machine_dup = line(status: 'auto_matched', sp: sp_new, sku: 'U1B')

      result = service.scan

      expect(result[:flagged]).to eq(1)
      expect(machine_dup.reload.possible_duplicate_of_id).to eq(chef_line.id)
      expect(chef_line.reload.possible_duplicate_of_id).to be_nil
    end

    it 'never flags chef-touched lines even when they duplicate each other' do
      sp = create(:supplier_product, supplier: usf, supplier_sku: 'U1', product: spine)
      sp2 = create(:supplier_product, supplier: usf, supplier_sku: 'U2', product: spine)
      line(status: 'manual', sp: sp, sku: 'U1')
      line(status: 'confirmed', sp: sp2, sku: 'U2')

      result = service.scan

      expect(result[:flagged]).to eq(0)
    end

    it 'does not re-flag a line the chef dismissed' do
      sp_old = create(:supplier_product, supplier: usf, supplier_sku: 'U1', product: spine)
      sp_new = create(:supplier_product, supplier: usf, supplier_sku: 'U1B', product: spine)
      line(status: 'auto_matched', sp: sp_old, sku: 'U1')
      dup = line(status: 'auto_matched', sp: sp_new, sku: 'U1B')

      service.scan
      service.dismiss!(dup.reload)
      result = service.scan

      expect(result[:flagged]).to eq(0)
      expect(dup.reload.possible_duplicate_of_id).to be_nil
    end

    it 'counts zero-item husks' do
      create(:product_match, aggregated_list: aggregated_list, match_status: 'rejected')

      expect(service.scan[:empty]).to eq(1)
    end
  end

  describe '#merge!' do
    it 'moves missing-supplier items to the keeper, drops redundant ones, deletes the duplicate line' do
      sysco = create(:supplier, name: 'Sysco')
      sysco_list = create(:supplier_list, supplier: sysco, organization: org, location: location)

      sp_old = create(:supplier_product, supplier: usf, supplier_sku: 'U1', product: spine)
      sp_new = create(:supplier_product, supplier: usf, supplier_sku: 'U1B', product: spine)
      keeper = line(status: 'auto_matched', sp: sp_old, sku: 'U1')

      dup = line(status: 'auto_matched', sp: sp_new, sku: 'U1B')
      sysco_sp = create(:supplier_product, supplier: sysco, supplier_sku: 'S1', product: spine)
      sysco_sli = create(:supplier_list_item, supplier_list: sysco_list, sku: 'S1', supplier_product: sysco_sp)
      create(:product_match_item, product_match: dup, supplier_list_item: sysco_sli)

      service.scan
      service.merge!(dup.reload)

      expect(ProductMatch.exists?(dup.id)).to be(false)
      supplier_ids = keeper.reload.product_match_items.map(&:supplier_id)
      # Keeper gains the Sysco item; the redundant USF copy is dropped
      expect(supplier_ids).to match_array([usf.id, sysco.id])
      # The dropped PMI's SupplierListItem survives — only the grouping went away
      expect(SupplierListItem.exists?(sku: 'U1B')).to be(true)
    end

    it 'repoints chef order-list rows and current-order carts to the keeper (ordering safety)' do
      sp_old = create(:supplier_product, supplier: usf, supplier_sku: 'U1', product: spine)
      sp_new = create(:supplier_product, supplier: usf, supplier_sku: 'U1B', product: spine)
      keeper = line(status: 'auto_matched', sp: sp_old, sku: 'U1')
      dup = line(status: 'auto_matched', sp: sp_new, sku: 'U1B')

      order_list = OrderList.create!(user: user, organization: org, location: location, name: 'Weekly')
      oli = order_list.order_list_items.create!(product_match: dup, quantity: 3)
      current_order = CurrentOrder.create!(
        user: user, aggregated_list: aggregated_list,
        state: { dup.id.to_s => { 'supplierId' => usf.id.to_s, 'qty' => 2, 'uom' => 'CS' } }
      )

      service.scan
      service.merge!(dup.reload)

      # The chef's order-list row survives, pointed at the keeper
      expect(oli.reload.product_match_id).to eq(keeper.id)
      # The in-progress cart entry follows the merge instead of vanishing
      expect(current_order.reload.state).to have_key(keeper.id.to_s)
      expect(current_order.state).not_to have_key(dup.id.to_s)
      expect(current_order.sanitized_state[keeper.id.to_s]['qty']).to eq(2.0)
    end

    it 'refuses to merge an unflagged line' do
      sp = create(:supplier_product, supplier: usf, supplier_sku: 'U1', product: spine)
      pm = line(status: 'auto_matched', sp: sp, sku: 'U1')

      expect { service.merge!(pm) }.to raise_error(ArgumentError)
    end
  end

  describe '#auto_merge_same_product' do
    # The self-dup arises when a second list of the SAME supplier (CW's
    # Previously Purchased) carries the same supplier_product as the guide.
    let(:second_usf_list) { create(:supplier_list, supplier: usf, organization: org, location: location) }

    def second_list_line(status:, sp:, sku:)
      sli = create(:supplier_list_item, supplier_list: second_usf_list, sku: sku, supplier_product: sp)
      pm = create(:product_match, aggregated_list: aggregated_list, match_status: status)
      create(:product_match_item, product_match: pm, supplier_list_item: sli)
      pm
    end

    it 'collapses machine lines holding the identical supplier_product, keeper first' do
      sp = create(:supplier_product, supplier: usf, supplier_sku: 'U1', product: spine)
      keeper = line(status: 'auto_matched', sp: sp, sku: 'U1')
      self_dup = second_list_line(status: 'auto_matched', sp: sp, sku: 'U1')

      merged = service.auto_merge_same_product

      expect(merged).to eq(1)
      expect(ProductMatch.exists?(keeper.id)).to be(true)
      expect(ProductMatch.exists?(self_dup.id)).to be(false)
    end

    it 'never auto-merges chef-touched lines and prefers them as keepers' do
      sp = create(:supplier_product, supplier: usf, supplier_sku: 'U1', product: spine)
      machine = line(status: 'auto_matched', sp: sp, sku: 'U1')
      chef_line = second_list_line(status: 'manual', sp: sp, sku: 'U1')

      merged = service.auto_merge_same_product

      expect(merged).to eq(1)
      expect(ProductMatch.exists?(chef_line.id)).to be(true)
      expect(ProductMatch.exists?(machine.id)).to be(false)
    end

    it 'leaves lines with distinct supplier products alone' do
      sp_a = create(:supplier_product, supplier: usf, supplier_sku: 'U1', product: spine)
      sp_b = create(:supplier_product, supplier: usf, supplier_sku: 'U2', product: spine)
      line(status: 'auto_matched', sp: sp_a, sku: 'U1')
      line(status: 'auto_matched', sp: sp_b, sku: 'U2')

      expect(service.auto_merge_same_product).to eq(0)
      expect(aggregated_list.product_matches.count).to eq(2)
    end
  end

  describe '#bulk_merge_exact' do
    it 'merges provable duplicates but leaves pairs with unmatched extra items for review' do
      sysco = create(:supplier, name: 'Sysco')
      sysco_list = create(:supplier_list, supplier: sysco, organization: org, location: location)
      other_spine = create(:product)

      # Exact duplicate: single USF item, spine-identical to its keeper
      sp_a = create(:supplier_product, supplier: usf, supplier_sku: 'U1', product: spine)
      sp_b = create(:supplier_product, supplier: usf, supplier_sku: 'U1B', product: spine)
      line(status: 'auto_matched', sp: sp_a, sku: 'U1')
      exact_dup = line(status: 'auto_matched', sp: sp_b, sku: 'U1B')

      # Non-exact: flagged via the shared USF item, but carries a Sysco item
      # (different spine) its keeper lacks — needs human judgment
      sp_c = create(:supplier_product, supplier: usf, supplier_sku: 'U2', product: other_spine)
      sp_d = create(:supplier_product, supplier: usf, supplier_sku: 'U2B', product: other_spine)
      line(status: 'auto_matched', sp: sp_c, sku: 'U2')
      partial_dup = line(status: 'auto_matched', sp: sp_d, sku: 'U2B')
      stray_spine = create(:product)
      sysco_sp = create(:supplier_product, supplier: sysco, supplier_sku: 'S9', product: stray_spine)
      sysco_sli = create(:supplier_list_item, supplier_list: sysco_list, sku: 'S9', supplier_product: sysco_sp)
      create(:product_match_item, product_match: partial_dup, supplier_list_item: sysco_sli)

      service.scan
      merged = service.bulk_merge_exact

      expect(merged).to eq(1)
      expect(ProductMatch.exists?(exact_dup.id)).to be(false)
      expect(ProductMatch.exists?(partial_dup.id)).to be(true)
      expect(partial_dup.reload.possible_duplicate_of_id).to be_present
    end

    it 'never bulk-merges a chef-touched line even if flagged somehow' do
      sp_a = create(:supplier_product, supplier: usf, supplier_sku: 'U1', product: spine)
      sp_b = create(:supplier_product, supplier: usf, supplier_sku: 'U1B', product: spine)
      keeper = line(status: 'auto_matched', sp: sp_a, sku: 'U1')
      chef_line = line(status: 'manual', sp: sp_b, sku: 'U1B')
      chef_line.update!(possible_duplicate_of_id: keeper.id)

      expect(service.bulk_merge_exact).to eq(0)
      expect(ProductMatch.exists?(chef_line.id)).to be(true)
    end
  end

  describe '#purge_empty' do
    it 'removes zero-item machine lines but never chef-touched ones' do
      create(:product_match, aggregated_list: aggregated_list, match_status: 'rejected')
      create(:product_match, aggregated_list: aggregated_list, match_status: 'unmatched')
      keeper = create(:product_match, aggregated_list: aggregated_list, match_status: 'manual')

      expect(service.purge_empty).to eq(2)
      expect(ProductMatch.exists?(keeper.id)).to be(true)
      expect(aggregated_list.product_matches.count).to eq(1)
    end

    it 'never purges a husk still referenced by an order-list row (ordering safety)' do
      referenced_husk = create(:product_match, aggregated_list: aggregated_list, match_status: 'rejected')
      unreferenced_husk = create(:product_match, aggregated_list: aggregated_list, match_status: 'rejected')
      order_list = OrderList.create!(user: user, organization: org, location: location, name: 'Weekly')
      oli = order_list.order_list_items.create!(product_match: referenced_husk, quantity: 1)

      expect(service.purge_empty).to eq(1)
      expect(ProductMatch.exists?(referenced_husk.id)).to be(true)
      expect(ProductMatch.exists?(unreferenced_husk.id)).to be(false)
      expect(oli.reload.product_match_id).to eq(referenced_husk.id)
    end
  end
end
