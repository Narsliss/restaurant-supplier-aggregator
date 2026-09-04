require 'rails_helper'

RSpec.describe SeedOrderListsService do
  let(:user) { create(:user, :with_organization) }
  let(:org) { user.current_organization }
  let(:location) { create(:location, organization: org, user: user) }
  let(:supplier) { create(:supplier, name: 'US Foods') }
  let(:credential) do
    create(:supplier_credential, supplier: supplier, user: user,
                                 organization_id: org.id, location_id: location.id)
  end

  def make_source_list(list_type:, remote_id:, skus:, linked: true)
    list = create(:supplier_list, supplier: supplier, organization: org, location: location,
                                  list_type: list_type, remote_list_id: remote_id)
    skus.each_with_index do |sku, i|
      sp = if linked
             create(:supplier_product, supplier: supplier, supplier_sku: sku,
                                       product: Product.create!(name: "Product #{sku}"))
           else
             create(:supplier_product, supplier: supplier, supplier_sku: sku, product: nil)
           end
      create(:supplier_list_item, supplier_list: list, sku: sku, name: "Item #{sku}",
                                  position: i, supplier_product: sp)
    end
    list
  end

  describe 'seeding from a recently-purchased list' do
    it 'creates a "Recent <Supplier> Orders" list with spine-linked items in guide order' do
      make_source_list(list_type: 'recently_purchased', remote_id: 'recentlyPurchased', skus: %w[A B C])

      results = described_class.new(credential).call

      expect(results[:seeded]).to be(true)
      list = OrderList.find_by(location: location, seed_supplier_id: supplier.id)
      expect(list.name).to eq('Recent US Foods Orders')
      expect(list.seeded_at).to be_present
      expect(list.order_list_items.by_position.map { |i| i.product.name })
        .to eq(['Product A', 'Product B', 'Product C'])
    end

    it 'skips items with no spine product link' do
      list = make_source_list(list_type: 'recently_purchased', remote_id: 'recentlyPurchased', skus: %w[A])
      unlinked_sp = create(:supplier_product, supplier: supplier, supplier_sku: 'X', product: nil)
      create(:supplier_list_item, supplier_list: list, sku: 'X', name: 'Item X',
                                  position: 9, supplier_product: unlinked_sp)

      results = described_class.new(credential).call

      expect(results[:items]).to eq(1)
      expect(results[:skipped]).to eq(1)
    end

    it 'never auto-resurrects a seeded list the chef deleted (tombstone survives deletion)' do
      make_source_list(list_type: 'recently_purchased', remote_id: 'recentlyPurchased', skus: %w[A])
      described_class.new(credential).call
      OrderList.find_by(location: location, seed_supplier_id: supplier.id).destroy!

      # Daily sync fires the auto path again — the deleted list must stay gone
      results = described_class.new(credential).call

      expect(results[:seeded]).to be(false)
      expect(results[:reason]).to eq(:already_seeded)
      expect(OrderList.for_location(location).where.not(seed_supplier_id: nil)).to be_empty
    end

    it 'lets the explicit refresh button re-create a deleted seeded list' do
      make_source_list(list_type: 'recently_purchased', remote_id: 'recentlyPurchased', skus: %w[A])
      described_class.new(credential).call
      OrderList.find_by(location: location, seed_supplier_id: supplier.id).destroy!

      results = described_class.new(credential).refresh

      expect(results[:seeded]).to be(true)
      expect(OrderList.find_by(location: location, seed_supplier_id: supplier.id)).to be_present
    end

    it 'never creates a duplicate list — a second call re-mirrors the existing one' do
      make_source_list(list_type: 'recently_purchased', remote_id: 'recentlyPurchased', skus: %w[A])

      described_class.new(credential).call
      results = described_class.new(credential).call

      expect(results[:refreshed]).to be(true)
      expect(OrderList.for_location(location).count).to eq(1)
    end

    it 'keeps an existing seeded list mirroring the supplier feed on every sync' do
      source = make_source_list(list_type: 'recently_purchased', remote_id: 'recentlyPurchased', skus: %w[A B])
      described_class.new(credential).call
      list = OrderList.find_by(location: location, seed_supplier_id: supplier.id)

      # Supplier feed drops B and gains C before the next daily sync
      source.supplier_list_items.find_by(sku: 'B').destroy!
      sp = create(:supplier_product, supplier: supplier, supplier_sku: 'C',
                                     product: Product.create!(name: 'Product C'))
      create(:supplier_list_item, supplier_list: source, sku: 'C', name: 'Item C',
                                  position: 5, supplier_product: sp)

      described_class.new(credential).call

      expect(list.reload.order_list_items.by_position.map { |i| i.product.name })
        .to eq(['Product A', 'Product C'])
    end
  end

  describe 'source preference and naming' do
    it "seeds from Chef's Warehouse guide -1 (favorites) as recent orders" do
      cw = create(:supplier, name: "Chef's Warehouse")
      cw_cred = create(:supplier_credential, supplier: cw, user: user,
                                             organization_id: org.id, location_id: location.id)
      list = create(:supplier_list, supplier: cw, organization: org, location: location,
                                    list_type: 'favorites', remote_list_id: '-1')
      sp = create(:supplier_product, supplier: cw, supplier_sku: 'CW1',
                                     product: Product.create!(name: 'CW Product'))
      create(:supplier_list_item, supplier_list: list, sku: 'CW1', name: 'CW Item',
                                  position: 0, supplier_product: sp)

      results = described_class.new(cw_cred).call

      expect(results[:seeded]).to be(true)
      expect(results[:list_name]).to eq("Recent Chef's Warehouse Orders")
    end

    it 'names a static order-guide seed after the guide, not "Recent Orders"' do
      wcw = create(:supplier, name: 'What Chefs Want')
      wcw_cred = create(:supplier_credential, supplier: wcw, user: user,
                                              organization_id: org.id, location_id: location.id)
      list = create(:supplier_list, supplier: wcw, organization: org, location: location,
                                    list_type: 'order_guide', remote_list_id: 'order-guide')
      sp = create(:supplier_product, supplier: wcw, supplier_sku: 'W1',
                                     product: Product.create!(name: 'WCW Product'))
      create(:supplier_list_item, supplier_list: list, sku: 'W1', name: 'WCW Item',
                                  position: 0, supplier_product: sp)

      results = described_class.new(wcw_cred).call

      expect(results[:list_name]).to eq('What Chefs Want Order Guide')
    end

    it 'never seeds from vendor-curated lists (USF OG-*/custom, Sysco marketing lists)' do
      make_source_list(list_type: 'order_guide', remote_id: 'OG-853237', skus: %w[A])
      make_source_list(list_type: 'custom', remote_id: 'SL-123', skus: %w[B])

      results = described_class.new(credential).call

      expect(results[:seeded]).to be(false)
      expect(results[:reason]).to eq(:no_seed_source)
    end
  end

  describe '#refresh (chef-pressed button)' do
    it 'mirrors the supplier feed: adds new items, drops removed ones, tracks guide order' do
      source = make_source_list(list_type: 'recently_purchased', remote_id: 'recentlyPurchased', skus: %w[A B])
      described_class.new(credential).call
      list = OrderList.find_by(location: location, seed_supplier_id: supplier.id)
      kept_item_id = list.order_list_items.joins(:product).find_by(products: { name: 'Product A' }).id

      # Supplier feed drops B and gains C
      source.supplier_list_items.find_by(sku: 'B').destroy!
      sp = create(:supplier_product, supplier: supplier, supplier_sku: 'C',
                                     product: Product.create!(name: 'Product C'))
      create(:supplier_list_item, supplier_list: source, sku: 'C', name: 'Item C',
                                  position: 5, supplier_product: sp)

      results = described_class.new(credential).refresh

      expect(results[:refreshed]).to be(true)
      expect(list.reload.order_list_items.by_position.map { |i| i.product.name })
        .to eq(['Product A', 'Product C'])
      # A kept as the same row, not destroyed and re-created
      expect(list.order_list_items.where(id: kept_item_id)).to exist
    end

    it 'never wipes the list when the feed comes back with no seedable items (bad sync guard)' do
      source = make_source_list(list_type: 'recently_purchased', remote_id: 'recentlyPurchased', skus: %w[A])
      described_class.new(credential).call
      list = OrderList.find_by(location: location, seed_supplier_id: supplier.id)

      source.supplier_list_items.destroy_all

      results = described_class.new(credential).refresh

      expect(results[:reason]).to eq(:no_seedable_items)
      expect(list.reload.order_list_items.count).to eq(1)
    end

    it 'reports zero additions when nothing new was ordered' do
      make_source_list(list_type: 'recently_purchased', remote_id: 'recentlyPurchased', skus: %w[A])
      described_class.new(credential).call

      results = described_class.new(credential).refresh

      expect(results[:refreshed]).to be(true)
      expect(results[:items]).to eq(0)
    end

    it 'creates the seeded list even when the location curates its own lists' do
      make_source_list(list_type: 'recently_purchased', remote_id: 'recentlyPurchased', skus: %w[A])
      OrderList.create!(user: user, organization: org, location: location, name: 'My prep list')

      results = described_class.new(credential).refresh

      expect(results[:seeded]).to be(true)
      expect(results[:refreshed]).to be(false)
      expect(OrderList.find_by(location: location, seed_supplier_id: supplier.id)).to be_present
    end
  end

  describe 'post-scrape refresh via ImportSupplierListsJob (refresh_seeded)' do
    it 'creates the seeded list once the live fetch lands' do
      make_source_list(list_type: 'recently_purchased', remote_id: 'recentlyPurchased', skus: %w[A])
      allow_any_instance_of(ImportSupplierListsService).to receive(:call)
        .and_return({ lists_synced: 1, items_imported: 1, items_updated: 0, errors: [] })

      ImportSupplierListsJob.perform_now(credential.id, force: true, refresh_seeded: true)

      expect(OrderList.find_by(location: location, seed_supplier_id: supplier.id)).to be_present
    end
  end

  describe 'safety rails' do
    it 'never seeds a location that already curates its own order lists' do
      make_source_list(list_type: 'recently_purchased', remote_id: 'recentlyPurchased', skus: %w[A])
      OrderList.create!(user: user, organization: org, location: location, name: 'My prep list')

      results = described_class.new(credential).call

      expect(results[:seeded]).to be(false)
      expect(results[:reason]).to eq(:location_has_own_lists)
    end

    it 'still seeds a second supplier after the first seeded (seeded lists do not block)' do
      make_source_list(list_type: 'recently_purchased', remote_id: 'recentlyPurchased', skus: %w[A])
      described_class.new(credential).call

      wcw = create(:supplier, name: 'What Chefs Want')
      wcw_cred = create(:supplier_credential, supplier: wcw, user: user,
                                              organization_id: org.id, location_id: location.id)
      list = create(:supplier_list, supplier: wcw, organization: org, location: location,
                                    list_type: 'order_guide', remote_list_id: 'order-guide')
      sp = create(:supplier_product, supplier: wcw, supplier_sku: 'W1',
                                     product: Product.create!(name: 'WCW Product'))
      create(:supplier_list_item, supplier_list: list, sku: 'W1', name: 'WCW Item',
                                  position: 0, supplier_product: sp)

      results = described_class.new(wcw_cred).call

      expect(results[:seeded]).to be(true)
      expect(OrderList.for_location(location).count).to eq(2)
    end
  end
end
