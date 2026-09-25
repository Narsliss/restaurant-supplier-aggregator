require "rails_helper"
require "rake"

# baseline:attach — a newly added supplier (e.g. Performance) joins the existing
# Claude baseline by moving ONLY its own products onto matched spine Products.
RSpec.describe "baseline:attach", type: :task do
  before(:all) do
    Rake.application.rake_require("tasks/baseline_match") unless Rake::Task.task_defined?("baseline:attach")
    Rake::Task.define_task(:environment)
  end

  let(:org) { create(:organization) }
  # The seed_suppliers initializer creates these in every environment, test included.
  let(:usf) { Supplier.find_by(code: "usfoods") || create(:supplier, name: "US Foods", code: "usfoods") }
  let(:pfg) { Supplier.find_by(code: "performance") || create(:supplier, name: "Performance Foodservice", code: "performance") }

  # USF oil already sits in a baseline group (canonical); PFG oil is on its own Product.
  let(:canonical) { create(:product, name: "Oil Pomace Olive") }
  let(:pfg_own)   { create(:product, name: "PFG pomace") }
  let!(:usf_sp) do
    create(:supplier_product, supplier: usf, supplier_sku: "U1", current_price: 105.0, product: canonical,
                              match_source: "claude_baseline", match_confidence: "high")
  end
  let!(:pfg_sp) { create(:supplier_product, supplier: pfg, supplier_sku: "543638", current_price: 75.45, product: pfg_own) }

  let(:file) { Rails.root.join("tmp/baseline_attach_spec_#{Process.pid}.json") }
  let(:rows) { [{ "sku" => "543638", "target" => { "supplier" => "usfoods", "sku" => "U1" }, "confidence" => "high" }] }

  around do |ex|
    File.write(file, rows.to_json)
    ex.run
  ensure
    File.delete(file) if File.exist?(file)
    %w[baseline:attach baseline:rollback].each { |t| Rake::Task[t].reenable }
  end

  def run(task, env = {})
    env.each { |k, v| ENV[k] = v }
    Rake::Task[task].invoke
  ensure
    env.each_key { |k| ENV.delete(k) }
    Rake::Task[task].reenable
  end

  def attach(extra = {})
    run("baseline:attach", { "SUPPLIER" => "performance", "FILE" => file.to_s, "RUN_TAG" => "t" }.merge(extra))
  end

  it "dry run writes nothing" do
    expect { attach }.not_to change { pfg_sp.reload.product_id }
    expect(BaselineLinkSnapshot.count).to eq(0)
  end

  it "moves ONLY the new supplier's product onto the target's Product and stamps provenance" do
    usf_before = usf_sp.reload.attributes.slice("product_id", "match_source", "match_confidence")
    attach("APPLY" => "1")

    expect(pfg_sp.reload.product_id).to eq(canonical.id)
    expect(pfg_sp.match_source).to eq("claude_baseline")
    expect(pfg_sp.match_confidence).to eq("high")
    expect(usf_sp.reload.attributes.slice("product_id", "match_source", "match_confidence")).to eq(usf_before)
    expect(canonical.reload.supplier_product_for(pfg)).to eq(pfg_sp)
  end

  it "rolls back exactly (restores product_id, clears provenance)" do
    attach("APPLY" => "1")
    run("baseline:rollback", "RUN_TAG" => "t", "APPLY" => "1")

    expect(pfg_sp.reload.product_id).to eq(pfg_own.id)
    expect(pfg_sp.match_source).to be_nil
    expect(usf_sp.reload.match_source).to eq("claude_baseline") # original baseline untouched by rollback
  end

  context "one product per supplier per canonical" do
    let!(:pfg_sp2) { create(:supplier_product, supplier: pfg, supplier_sku: "999", current_price: 70.0, product: create(:product)) }
    let(:rows) do
      [{ "sku" => "543638", "target" => { "supplier" => "usfoods", "sku" => "U1" }, "confidence" => "high" },
       { "sku" => "999",    "target" => { "supplier" => "usfoods", "sku" => "U1" }, "confidence" => "medium" }]
    end

    it "attaches the first row and skips a second PFG product for the same canonical" do
      attach("APPLY" => "1")
      expect(pfg_sp.reload.product_id).to eq(canonical.id)
      expect(pfg_sp2.reload.product_id).not_to eq(canonical.id)
    end
  end

  it "defers a product whose current Product is referenced by an order list" do
    chef = create(:user, current_organization: org)
    location = create(:location, organization: org)
    ol = OrderList.create!(user: chef, name: "Weekly", location: location, organization_id: org.id)
    ol.order_list_items.create!(product: pfg_own, quantity: 2)

    attach("APPLY" => "1")
    expect(pfg_sp.reload.product_id).to eq(pfg_own.id)
    expect(BaselineLinkSnapshot.count).to eq(0)
  end

  it "skips stale rows (sku no longer in catalog)" do
    File.write(file, [{ "sku" => "GONE", "target" => { "supplier" => "usfoods", "sku" => "U1" } }].to_json)
    expect { attach("APPLY" => "1") }.not_to change { BaselineLinkSnapshot.count }
  end

  it "never touches chef ProductMatch data" do
    agg = create(:aggregated_list)
    sl = create(:supplier_list, supplier: usf, organization: agg.organization)
    sli = create(:supplier_list_item, supplier_list: sl, supplier_product: usf_sp)
    match = create(:product_match, aggregated_list: agg, match_status: "confirmed")
    pmi = create(:product_match_item, product_match: match, supplier_list_item: sli, supplier: usf)

    attach("APPLY" => "1")
    expect(pmi.reload.supplier_list_item_id).to eq(sli.id)
    expect(match.reload.match_status).to eq("confirmed")
  end
end
