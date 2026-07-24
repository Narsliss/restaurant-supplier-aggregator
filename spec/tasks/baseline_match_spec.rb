require "rails_helper"
require "rake"

# Phase C apply: links Claude baseline groups onto the Product spine, reversibly,
# WITHOUT changing chef matches or how any order builds.
RSpec.describe "baseline:apply / rollback", type: :task do
  before(:all) do
    Rake.application.rake_require("tasks/baseline_match") unless Rake::Task.task_defined?("baseline:apply")
    Rake::Task.define_task(:environment)
  end

  let(:org) { create(:organization) }
  let(:usf) { create(:supplier, name: "US Foods") }
  let(:cw)  { create(:supplier, name: "Chef's Warehouse") }

  # Two supplier products Claude grouped as the same canonical item, each under
  # its own legacy Product.
  let(:prod_a) { create(:product, name: "USF chicken") }
  let(:prod_b) { create(:product, name: "CW chicken") }
  let!(:sp_a) { create(:supplier_product, supplier: usf, supplier_sku: "A1", current_price: 68.9, product: prod_a) }
  let!(:sp_b) { create(:supplier_product, supplier: cw,  supplier_sku: "B1", current_price: 74.2, product: prod_b) }

  let(:groups_file) { Rails.root.join("db/baseline/claude_baseline_groups.json") }
  let(:fixture) do
    [{
      "confidence" => "high", "canonical_hint" => "Chicken Breast Boneless Skinless", "category" => "Protein",
      "members" => [
        { "sp_id" => sp_a.id, "supplier" => "US Foods", "name" => "USF chicken", "existing_pid" => prod_a.id },
        { "sp_id" => sp_b.id, "supplier" => "Chef's Warehouse", "name" => "CW chicken", "existing_pid" => prod_b.id },
      ],
    }]
  end

  around do |ex|
    original = File.exist?(groups_file) ? File.read(groups_file) : nil
    File.write(groups_file, fixture.to_json)
    ex.run
    original ? File.write(groups_file, original) : File.delete(groups_file)
    %w[baseline:apply baseline:rollback baseline:status].each { |t| Rake::Task[t].reenable }
  end

  def run(task, env = {})
    env.each { |k, v| ENV[k] = v }
    Rake::Task[task].invoke
  ensure
    env.each_key { |k| ENV.delete(k) }
  end

  it "dry run writes nothing" do
    expect { run("baseline:apply") }.not_to change { sp_a.reload.product_id }
    expect(BaselineLinkSnapshot.count).to eq(0)
  end

  it "APPLY=1 links both supplier products to one canonical and stamps provenance" do
    run("baseline:apply", "APPLY" => "1", "RUN_TAG" => "test_run")
    expect(sp_a.reload.product_id).to eq(sp_b.reload.product_id)
    expect(sp_a.match_source).to eq("claude_baseline")
    expect(sp_a.match_confidence).to eq("high")
    expect(BaselineLinkSnapshot.where(run_tag: "test_run", record_type: "SupplierProduct").count).to eq(2)
  end

  it "is idempotent — a second apply links nothing new" do
    run("baseline:apply", "APPLY" => "1", "RUN_TAG" => "test_run")
    Rake::Task["baseline:apply"].reenable
    expect { run("baseline:apply", "APPLY" => "1", "RUN_TAG" => "test_run") }
      .not_to change { BaselineLinkSnapshot.count }
  end

  it "rollback restores the exact previous product_ids and clears provenance" do
    before_a, before_b = sp_a.product_id, sp_b.product_id
    run("baseline:apply", "APPLY" => "1", "RUN_TAG" => "test_run")
    run("baseline:rollback", "APPLY" => "1", "RUN_TAG" => "test_run")
    expect(sp_a.reload.product_id).to eq(before_a)
    expect(sp_b.reload.product_id).to eq(before_b)
    expect(sp_a.match_source).to be_nil
    expect(BaselineLinkSnapshot.count).to eq(0)
  end

  it "does not touch chef ProductMatch data" do
    agg = create(:aggregated_list)
    sl = create(:supplier_list, supplier: usf, organization: agg.organization)
    sli = create(:supplier_list_item, supplier_list: sl, supplier_product: sp_a)
    match = create(:product_match, aggregated_list: agg, match_status: "confirmed")
    pmi = create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: usf)

    run("baseline:apply", "APPLY" => "1", "RUN_TAG" => "test_run")

    expect(pmi.reload.supplier_list_item_id).to eq(sli.id)
    expect(match.reload.match_status).to eq("confirmed")
    expect(sli.reload.supplier_product_id).to eq(sp_a.id)
  end

  it "skips a group that no longer spans two suppliers (catalog drift)" do
    sp_b.destroy
    expect { run("baseline:apply", "APPLY" => "1", "RUN_TAG" => "test_run") }
      .not_to change { BaselineLinkSnapshot.count }
  end

  # THE ORDERING SAFETY GATE: an OrderList must build the IDENTICAL order
  # after the baseline as before. The apply repoints the OrderListItem to the
  # canonical so OrderBuilderService#build still resolves the same supplier product.
  describe "OrderList order builder integrity" do
    let(:chef) do
      u = create(:user, current_organization: org)
      m = create(:membership, user: u, organization: org, role: "chef", active: true)
      m.membership_locations.create!(location: location)
      u
    end
    let(:location) { create(:location, organization: org) }
    let!(:order_list) do
      ol = OrderList.create!(user: chef, name: "My Weekly", location: location, organization_id: org.id)
      ol.order_list_items.create!(product: prod_a, quantity: 3)
      ol
    end

    def built_order_signature
      order = Orders::OrderBuilderService.new(user: chef, order_list: order_list, supplier: usf, location: location).build
      order.order_items.map { |oi| [oi.supplier_product_id, oi.quantity.to_i, oi.unit_price.to_f, oi.line_total.to_f] }.sort
    end

    it "builds the exact same order at USF before and after the baseline" do
      before_sig = built_order_signature
      expect(before_sig).to eq([[sp_a.id, 3, 68.9, 206.7]])

      run("baseline:apply", "APPLY" => "1", "RUN_TAG" => "test_run")
      order_list.reload

      after_sig = built_order_signature
      expect(after_sig).to eq(before_sig)
      # The item was repointed to the canonical (not left orphaned on emptied prod_a)
      expect(order_list.order_list_items.first.product_id).to eq(sp_a.reload.product_id)
    end

    it "repoints an OrderListItem off an emptied Product, snapshots it, and rolls back" do
      # Force prod_a to win canonical (2 members) so prod_b is emptied and the
      # item on prod_b must be repointed. A SEPARATE order list holds the prod_b
      # item (no same-list collision).
      wcw = create(:supplier, name: "What Chefs Want")
      sp_c = create(:supplier_product, supplier: wcw, supplier_sku: "C1", current_price: 71.5, product: prod_a)
      File.write(groups_file, [{
        "confidence" => "high", "canonical_hint" => "Chicken", "category" => "Protein",
        "members" => [{ "sp_id" => sp_a.id }, { "sp_id" => sp_b.id }, { "sp_id" => sp_c.id }],
      }].to_json)
      other = OrderList.create!(user: chef, name: "Other", location: location, organization_id: org.id)
      item = other.order_list_items.create!(product: prod_b, quantity: 2)

      run("baseline:apply", "APPLY" => "1", "RUN_TAG" => "test_run")

      expect(item.reload.product_id).to eq(prod_a.id) # repointed off emptied prod_b
      expect(BaselineLinkSnapshot.where(run_tag: "test_run", record_type: "OrderListItem", record_id: item.id).count).to eq(1)

      run("baseline:rollback", "APPLY" => "1", "RUN_TAG" => "test_run")
      expect(item.reload.product_id).to eq(prod_b.id)
    end

    it "defers a group that would collide within a single OrderList (unique constraint)" do
      # One list holds items on BOTH prod_a and prod_b — merging them would
      # violate the (order_list_id, product_id) unique index.
      order_list.order_list_items.create!(product: prod_b, quantity: 2)

      expect { run("baseline:apply", "APPLY" => "1", "RUN_TAG" => "test_run") }
        .not_to change { BaselineLinkSnapshot.count }
      expect(sp_a.reload.product_id).to eq(prod_a.id) # group not applied
    end
  end
end
