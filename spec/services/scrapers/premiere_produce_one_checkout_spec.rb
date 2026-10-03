require "rails_helper"

# PPO delivery date + submit confirmation (Oct 2026, order #387 diagnosis):
# PPO changed its schema so NewOrder_UpdateFulfillment was rejected on every
# order, and our code ignored it — a leftover draft would ship on its stale
# date. And a rejected submitOrder was recorded as "submitted" under a
# made-up PPO-<timestamp> confirmation. Both now fail closed.
RSpec.describe Scrapers::PremiereProduceOneScraper do
  let(:credential) { create(:supplier_credential) }
  let(:scraper) { described_class.new(credential) }
  let(:api) { double("PremiereProduceOneApi", ensure_session!: true) }
  let(:friday) { Date.new(2026, 10, 2) }
  let(:draft_uuid) { "draft-1" }
  let(:items) { [{ sku: "A1", quantity: 2, name: "Limes" }] }

  before do
    allow(scraper).to receive(:api_client).and_return(api)
    allow(api).to receive(:get_open_orders).and_return("orders" => [{ "uuid" => draft_uuid, "orders_items" => [] }])
    allow(api).to receive(:get_catalog).and_return(
      "getSupplierVariantPackGroupItems" => [{ "variant_pack" => { "external_item_id" => "A1", "uuid" => "vp-1", "item" => { "display_name" => "Limes" } } }]
    )
    allow(api).to receive(:update_cart).and_return("updateCart" => { "order" => { "uuid" => draft_uuid } })
  end

  def fulfillment_returning(time)
    { "update_orders" => { "returning" => [{ "uuid" => draft_uuid, "restaurant_desired_delivery_time" => time }] } }
  end

  describe "#add_to_cart delivery date" do
    it "fails closed when PPO rejects the date update (the live bug: result was nil)" do
      allow(api).to receive(:update_fulfillment).and_return(nil)

      expect { scraper.add_to_cart(items, delivery_date: friday) }
        .to raise_error(Scrapers::BaseScraper::DeliveryUnavailableError, /did not accept delivery on Fri Oct 2/)
    end

    it "fails closed when the draft matched nothing (Hasura returns an empty returning list)" do
      allow(api).to receive(:update_fulfillment).and_return("update_orders" => { "returning" => [] })

      expect { scraper.add_to_cart(items, delivery_date: friday) }
        .to raise_error(Scrapers::BaseScraper::DeliveryUnavailableError)
    end

    it "fails closed when PPO keeps a different day" do
      allow(api).to receive(:update_fulfillment).and_return(fulfillment_returning("2026-09-28T04:00:00+00:00"))

      expect { scraper.add_to_cart(items, delivery_date: friday) }
        .to raise_error(Scrapers::BaseScraper::DeliveryUnavailableError)
    end

    it "succeeds when PPO echoes the requested day" do
      allow(api).to receive(:update_fulfillment).and_return(fulfillment_returning("2026-10-02T04:00:00+00:00"))

      expect(scraper.add_to_cart(items, delivery_date: friday)).to include(added: 1)
    end

    it "sends Eastern midnight in daylight time" do
      expect(api).to receive(:update_fulfillment).with(draft_uuid, "2026-10-02T04:00:00.000Z")
        .and_return(fulfillment_returning("2026-10-02T04:00:00+00:00"))

      scraper.add_to_cart(items, delivery_date: friday)
    end

    it "sends Eastern midnight in standard time (a fixed 04:00Z would be 11 PM the day before)" do
      dec = Date.new(2026, 12, 10)
      expect(api).to receive(:update_fulfillment).with(draft_uuid, "2026-12-10T05:00:00.000Z")
        .and_return(fulfillment_returning("2026-12-10T05:00:00+00:00"))

      scraper.add_to_cart(items, delivery_date: dec)
    end
  end

  describe "#checkout" do
    let(:draft_date) { "2026-10-02T04:00:00+00:00" }

    before do
      allow(api).to receive(:update_fulfillment).and_return(fulfillment_returning("2026-10-02T04:00:00+00:00"))
      scraper.add_to_cart(items, delivery_date: friday)

      allow(api).to receive(:get_open_orders).and_return("orders" => [{
        "uuid" => draft_uuid, "restaurant_desired_delivery_time" => draft_date,
        "orders_items" => [{ "restaurant_display_name" => "Limes", "variants_pack" => { "uuid" => "vp-1" } }]
      }])
      allow(api).to receive(:get_product_info_list).and_return(
        "getVariantPackInfoList" => [{ "variant_pack_id" => "vp-1", "price_in_micros" => 12_500_000 }]
      )
    end

    context "when the draft is on a different day right before submit" do
      let(:draft_date) { "2026-09-28T04:00:00+00:00" }

      it "refuses to submit" do
        expect(api).not_to receive(:submit_order)

        expect { scraper.checkout(dry_run: false) }
          .to raise_error(Scrapers::BaseScraper::DeliveryUnavailableError)
      end

      it "also stops a dry run, so dev testing catches it" do
        expect { scraper.checkout(dry_run: true) }
          .to raise_error(Scrapers::BaseScraper::DeliveryUnavailableError)
      end
    end

    it "uses PPO's order id as the confirmation" do
      allow(api).to receive(:submit_order).and_return("submitOrder" => { "order" => { "uuid" => "ppo-123" } })

      expect(scraper.checkout(dry_run: false)).to include(confirmation_number: "ppo-123", dry_run: false)
    end

    # Shapes below are PPO's live answers to the OrderStatus lookup (Oct 3 2026).
    context "when submitOrder gives no order back" do
      before { allow(api).to receive(:submit_order).and_return(nil) }

      it "fails as not placed when the draft is still a DRAFT — never invents a confirmation" do
        allow(api).to receive(:get_order_status).with(draft_uuid).and_return(
          [{ "uuid" => draft_uuid, "status" => "DRAFT", "placed_at" => nil }]
        )

        expect { scraper.checkout(dry_run: false) }
          .to raise_error(Scrapers::BaseScraper::ScrapingError, /rejected the order. Nothing was placed/)
      end

      it "treats it as placed when PPO shows a placed_at" do
        allow(api).to receive(:get_order_status).with(draft_uuid).and_return(
          [{ "uuid" => draft_uuid, "status" => "DELIVERED", "placed_at" => "2026-10-01T20:30:57.274928+00:00" }]
        )

        expect(scraper.checkout(dry_run: false)).to include(confirmation_number: draft_uuid, dry_run: false)
      end
    end

    context "when submitOrder times out" do
      before { allow(api).to receive(:submit_order).and_raise(Net::ReadTimeout) }

      it "raises OrderUnconfirmedError when the status lookup fails too" do
        allow(api).to receive(:get_order_status).and_return(nil)

        expect { scraper.checkout(dry_run: false) }
          .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError, /Check the Premiere Produce app before reordering/)
      end

      it "raises OrderUnconfirmedError when PPO no longer knows the order" do
        allow(api).to receive(:get_order_status).and_return([])

        expect { scraper.checkout(dry_run: false) }
          .to raise_error(Scrapers::BaseScraper::OrderUnconfirmedError)
      end
    end
  end

  it "declares the fulfillment status filter as String (PPO's current schema)" do
    expect(Scrapers::PremiereProduceOneApi::UPDATE_FULFILLMENT_QUERY).to include("$unplacedOrderStatuses: [String!]")
  end
end
