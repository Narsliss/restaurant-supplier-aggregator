require "rails_helper"

# Premiere Produce order placement checks (Oct 2026, plan Phase 2). PPO had no
# line check: a line it dropped or changed went out short, a rejected cart
# update reached the chef as "SKU Limes — API rejected", clear_cart swallowed
# every error, checkout submitted "the first open order", and the total
# ignored quantity. And PPO splits orders onto later days without telling us
# (order 484, Oct 19 2026: 4 of 12 items moved to Oct 21, 22 and 28).
RSpec.describe Scrapers::PremiereProduceOneScraper do
  let(:credential) { create(:supplier_credential) }
  let(:scraper)    { described_class.new(credential) }
  let(:api)        { double("PremiereProduceOneApi", ensure_session!: true, last_error: nil) }
  let(:tuesday)    { Date.new(2026, 10, 20) }

  before { allow(scraper).to receive(:api_client).and_return(api) }

  # PPO's line shape (UPDATE_CART_QUERY / ORDER_LINES_QUERY, live Oct 19).
  def line(sku, qty, vp: "vp-#{sku}", name: "Item #{sku}")
    { "restaurant_display_name" => name, "order_item_prices" => { "pack_quantity_at_order" => qty },
      "variants_pack" => { "uuid" => vp, "external_item_id" => sku } }
  end

  def ppo_order(uuid, lines, status: "DRAFT", day: "2026-10-20T04:00:00+00:00")
    { "uuid" => uuid, "status" => status, "restaurant_desired_delivery_time" => day, "orders_items" => lines }
  end

  let(:expected) do
    [{ sku: "01298", name: "Bone Marrow", quantity: 1 }, { sku: "50445", name: "Parsley", quantity: 2 }]
  end

  describe "#add_to_cart" do
    let(:items) { [{ sku: "A1", quantity: 2, name: "Limes" }, { sku: "B2", quantity: 1, name: "Basil" }] }

    before do
      allow(api).to receive(:get_open_orders).and_return("orders" => [{ "uuid" => "draft-1", "orders_items" => [] }])
      allow(api).to receive(:get_catalog).and_return("getSupplierVariantPackGroupItems" => [
        { "variant_pack" => { "external_item_id" => "A1", "uuid" => "vp-A1", "item" => { "display_name" => "LIMES" } } },
        { "variant_pack" => { "external_item_id" => "B2", "uuid" => "vp-B2", "item" => { "display_name" => "BASIL" } } }
      ])
    end

    it "stops with PPO's own reason when the cart update is rejected (was 'SKU Limes — API rejected')" do
      allow(api).to receive(:update_cart).and_return(nil)
      allow(api).to receive(:last_error).and_return("variant pack is not orderable")

      expect { scraper.add_to_cart(items, delivery_date: tuesday) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, /rejected the cart update: variant pack is not orderable/)
    end

    it "names a line PPO left out of the cart, empties it, and does not set the date" do
      allow(api).to receive(:update_cart).and_return(
        { "updateCart" => { "order" => ppo_order("draft-1", [line("A1", 2)]) } },
        { "updateCart" => { "order" => ppo_order("draft-1", []) } }
      )
      allow(api).to receive(:get_open_orders).and_return(
        { "orders" => [{ "uuid" => "draft-1", "orders_items" => [] }] },
        { "orders" => [{ "uuid" => "draft-1", "orders_items" => [line("A1", 2)] }] },
        { "orders" => [{ "uuid" => "draft-1", "orders_items" => [] }] }
      )
      expect(api).not_to receive(:update_fulfillment)

      result = scraper.add_to_cart(items, delivery_date: tuesday)

      expect(result[:failed]).to eq([{ sku: "B2", name: "Basil", error: "Premiere Produce didn't add it to the cart" }])
    end

    it "stops instead of calling every item 'Not found in catalog' when the catalog read fails" do
      allow(api).to receive(:get_catalog).and_return(nil)

      expect { scraper.add_to_cart(items, delivery_date: tuesday) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, /Couldn't load Premiere Produce's catalog/)
    end
  end

  describe "#clear_cart" do
    it "fails closed when the cart cannot be read" do
      allow(api).to receive(:get_open_orders).and_return(nil)

      expect { scraper.clear_cart }.to raise_error(Scrapers::BaseScraper::ScrapingError, /Couldn't read the Premiere Produce cart/)
    end

    it "fails closed when lines are still there after the clear" do
      allow(api).to receive(:get_open_orders).and_return("orders" => [{ "uuid" => "d", "orders_items" => [line("A1", 1)] }])
      allow(api).to receive(:update_cart)

      expect { scraper.clear_cart }.to raise_error(Scrapers::BaseScraper::ScrapingError, /could not be emptied/)
    end

    it "passes when the draft comes back empty" do
      allow(api).to receive(:get_open_orders).and_return(
        { "orders" => [{ "uuid" => "d", "orders_items" => [line("A1", 1)] }] },
        { "orders" => [{ "uuid" => "d", "orders_items" => [] }] }
      )
      allow(api).to receive(:update_cart)

      expect { scraper.clear_cart }.not_to raise_error
    end
  end

  describe "#verify_cart_matches!" do
    before do
      scraper.instance_variable_set(:@order_uuid, "draft-1")
      allow(api).to receive(:update_cart)
      allow(api).to receive(:get_open_orders).and_return("orders" => [])
    end

    it "passes (leading zeros don't matter) and keeps the checked draft for checkout" do
      draft = ppo_order("draft-1", [line("1298", 1), line("50445", 2)])
      allow(api).to receive(:order_lines).with("draft-1").and_return(draft)

      expect(scraper.verify_cart_matches!(expected)).to be(true)
      expect(scraper.instance_variable_get(:@verified_order)).to eq(draft)
    end

    it "stops and names the line PPO dropped, using our SKU" do
      allow(api).to receive(:order_lines).and_return(ppo_order("draft-1", [line("50445", 2)]))

      expect { scraper.verify_cart_matches!(expected) }.to raise_error(Scrapers::BaseScraper::CartMismatchError) { |e|
        expect(e.discrepancies).to eq([{ type: "missing_from_cart", sku: "01298", expected_qty: 1.0 }])
      }
    end

    it "stops on a changed quantity" do
      allow(api).to receive(:order_lines).and_return(ppo_order("draft-1", [line("01298", 1), line("50445", 1)]))

      expect { scraper.verify_cart_matches!(expected) }.to raise_error(Scrapers::BaseScraper::CartMismatchError) { |e|
        expect(e.discrepancies).to eq([{ type: "quantity_mismatch", sku: "50445", cart_qty: 1.0, expected_qty: 2.0 }])
      }
    end

    it "stops on an extra line" do
      allow(api).to receive(:order_lines).and_return(ppo_order("draft-1", [line("01298", 1), line("50445", 2), line("777", 1)]))

      expect { scraper.verify_cart_matches!(expected) }.to raise_error(Scrapers::BaseScraper::CartMismatchError)
    end

    it "stops when the draft cannot be read back or is no longer a draft" do
      allow(api).to receive(:order_lines).and_return(ppo_order("draft-1", [line("01298", 1), line("50445", 2)], status: "SENT_TO_SUPPLIER"))

      expect { scraper.verify_cart_matches!(expected) }
        .to raise_error(Scrapers::BaseScraper::ScrapingError, /Couldn't read the Premiere Produce order back/)
    end

    it "makes Premiere Produce confirm its lines (supplier decides stock)" do
      expect(scraper.confirms_lines_before_submit?).to be(true)
    end
  end

  describe "#checkout" do
    let(:draft) { ppo_order("draft-1", [line("01298", 1, vp: "vp-1"), line("50445", 2, vp: "vp-2")]) }

    before do
      scraper.instance_variable_set(:@order_uuid, "draft-1")
      scraper.instance_variable_set(:@requested_delivery_date, tuesday)
      scraper.instance_variable_set(:@expected_cart_items, expected)
      scraper.instance_variable_set(:@verified_order, draft)
      allow(api).to receive(:get_open_orders).and_return("orders" => [
        ppo_order("someone-elses", [line("9", 1)]),
        ppo_order("draft-1", [line("01298", 1, vp: "vp-1"), line("50445", 2, vp: "vp-2")])
      ])
      allow(api).to receive(:get_product_info_list).and_return("getVariantPackInfoList" => [
        { "variant_pack_id" => "vp-1", "price_in_micros" => 10_000_000 },
        { "variant_pack_id" => "vp-2", "price_in_micros" => 12_500_000 }
      ])
    end

    it "submits OUR draft and totals price × quantity (was one price per line)" do
      expect(api).to receive(:submit_order).with("draft-1")
        .and_return("submitOrder" => { "order" => { "uuid" => "draft-1" }, "split_order_id_list" => [] })
      allow(api).to receive(:order_lines).with("draft-1").and_return(draft.merge("status" => "SENT_TO_SUPPLIER"))

      result = scraper.checkout(dry_run: false)

      expect(result[:total]).to eq(35.0) # 10 + 2 × 12.50
      expect(result[:supplier_exceptions]).to eq([])
    end

    # Order 484's shape: PPO moved items onto later days.
    it "reports items PPO moved to a later day" do
      allow(api).to receive(:submit_order)
        .and_return("submitOrder" => { "order" => { "uuid" => "draft-1" }, "split_order_id_list" => ["split-2"] })
      allow(api).to receive(:order_lines).with("draft-1")
        .and_return(ppo_order("draft-1", [line("50445", 2)], status: "SENT_TO_SUPPLIER"))
      allow(api).to receive(:order_lines).with("split-2")
        .and_return(ppo_order("split-2", [line("01298", 1)], status: "SENT_TO_SUPPLIER", day: "2026-10-28T04:00:00+00:00"))

      changes = scraper.checkout(dry_run: false)[:supplier_exceptions]

      expect(changes).to eq([{ sku: "01298", name: "Bone Marrow", type: "delivery_changed", ordered: 1.0, filled: 1.0,
                               message: "Arrives Wed Oct 28 — Premiere Produce put it on a separate order" }])
    end

    it "reports an item that is on none of the placed orders" do
      allow(api).to receive(:submit_order)
        .and_return("submitOrder" => { "order" => { "uuid" => "draft-1" }, "split_order_id_list" => [] })
      allow(api).to receive(:order_lines).with("draft-1")
        .and_return(ppo_order("draft-1", [line("50445", 2)], status: "SENT_TO_SUPPLIER"))

      changes = scraper.checkout(dry_run: false)[:supplier_exceptions]

      expect(changes).to eq([{ sku: "01298", name: "Bone Marrow", type: "removed", ordered: 1.0, filled: 0,
                               message: "Not on Premiere Produce's placed order" }])
    end

    it "claims nothing when a split order cannot be read — and never fails the placed order" do
      allow(api).to receive(:submit_order)
        .and_return("submitOrder" => { "order" => { "uuid" => "draft-1" }, "split_order_id_list" => ["split-2"] })
      allow(api).to receive(:order_lines).with("draft-1").and_return(ppo_order("draft-1", [line("50445", 2)]))
      allow(api).to receive(:order_lines).with("split-2").and_return(nil)

      result = scraper.checkout(dry_run: false)

      expect(result).to include(confirmation_number: "draft-1", supplier_exceptions: [])
    end
  end

  describe "availability (morning import and guide sync)" do
    it "is unknown, never 'in stock', when PPO's availability list fails" do
      expect(scraper.send(:ppo_in_stock, nil)).to be_nil
      expect(scraper.send(:ppo_in_stock, { "availability_status" => "OUT_OF_STOCK" })).to be(false)
      expect(scraper.send(:ppo_in_stock, { "availability_status" => "SPECIAL_ORDER" })).to be(true)
    end
  end
end
