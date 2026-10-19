require 'rails_helper'

RSpec.describe Orders::OrderPlacementService, type: :service do
  let(:user) { create(:user, :with_organization) }
  let(:supplier) { create(:supplier, checkout_enabled: false) }
  let!(:credential) { create(:supplier_credential, user: user, supplier: supplier, status: 'active') }
  let(:supplier_product) { create(:supplier_product, supplier: supplier) }
  let(:order) do
    create(:order, user: user, supplier: supplier, organization: user.current_organization).tap do |o|
      create(:order_item, order: o, supplier_product: supplier_product, quantity: 2, unit_price: 10)
    end
  end

  let(:fake_scraper_class) { double('FakeScraperClass') }
  let(:fake_scraper) do
    instance_double(
      'FakeScraper',
      clear_cart: nil,
      add_to_cart: { added: [], failed: [] },
      verify_cart_matches!: true,
      checkout: scraper_checkout_result,
      close_order_browser!: nil
    )
  end
  let(:scraper_checkout_result) do
    { dry_run: true, total: 25.00, confirmation_number: nil, delivery_date: nil, cart_items: [] }
  end

  before do
    allow(supplier).to receive(:scraper_klass).and_return(fake_scraper_class)
    allow(fake_scraper_class).to receive(:new).with(credential).and_return(fake_scraper)
    # The service reaches the supplier through `order.supplier`, so stub on the order's instance.
    allow(order).to receive(:supplier).and_return(supplier)

    # Skip thorough pre-order validation — covered in PreOrderValidationService specs.
    allow_any_instance_of(Orders::OrderValidationService).to receive(:validate!).and_return({ warnings: [], errors: [] })
  end

  describe 'dry-run gate' do
    context 'in test environment (the default)' do
      it 'forces dry_run=true even when supplier.checkout_enabled is true' do
        supplier.update!(checkout_enabled: true)

        expect(fake_scraper).to receive(:checkout).with(dry_run: true).and_return(scraper_checkout_result)

        described_class.new(order).place_order(skip_pre_validation: true)
      end
    end

    context 'when production env is simulated' do
      before { allow(Rails.env).to receive(:production?).and_return(true) }

      it 'submits as a real order when checkout_enabled is true' do
        supplier.update!(checkout_enabled: true)
        scraper_checkout_result.merge!(dry_run: false, confirmation_number: 'CONF-XYZ')

        expect(fake_scraper).to receive(:checkout).with(dry_run: false).and_return(scraper_checkout_result)

        result = described_class.new(order).place_order(skip_pre_validation: true)

        expect(result[:success]).to be true
        expect(order.reload.status).to eq('submitted')
        expect(order.confirmation_number).to eq('CONF-XYZ')
      end

      it 'forces dry_run=true when checkout_enabled is false (per-supplier kill switch)' do
        supplier.update!(checkout_enabled: false)

        expect(fake_scraper).to receive(:checkout).with(dry_run: true).and_return(scraper_checkout_result)

        result = described_class.new(order).place_order(skip_pre_validation: true)

        expect(result[:success]).to be true
        expect(result[:dry_run]).to be true
        expect(order.reload.status).to eq('dry_run_complete')
      end
    end
  end

  describe 'order status updates' do
    it 'sets status=dry_run_complete and marks items pending on a dry run' do
      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result).to include(success: true, dry_run: true)
      expect(order.reload.status).to eq('dry_run_complete')
      expect(order.order_items.pluck(:status).uniq).to eq(['pending'])
    end

    it 'falls back to calculated_subtotal when scraper returns no total' do
      scraper_checkout_result.merge!(total: 0)

      described_class.new(order).place_order(skip_pre_validation: true)

      expect(order.reload.total_amount).to eq(20.00) # 2 * 10
    end
  end

  # Order 484 (Oct 19 2026): Premiere Produce split 4 of 12 items onto later
  # days; EnPlace showed one order arriving with everything.
  describe 'supplier changes reported at placement' do
    before do
      allow(Rails.env).to receive(:production?).and_return(true)
      supplier.update!(checkout_enabled: true)
      scraper_checkout_result.merge!(
        dry_run: false, confirmation_number: 'ppo-1',
        supplier_exceptions: [{ sku: supplier_product.supplier_sku, name: 'Bone Marrow', type: 'delivery_changed',
                                ordered: 1, filled: 1, message: 'Arrives Wed Oct 28 — Premiere Produce put it on a separate order' }]
      )
    end

    it 'records them on the order and emails the chef and owner' do
      expect { described_class.new(order).place_order(skip_pre_validation: true) }
        .to have_enqueued_mail(OrderMailer, :supplier_changed_order)

      order.reload
      expect(order.status).to eq('submitted')
      expect(order.supplier_exceptions.first).to include('type' => 'delivery_changed', 'name' => 'Bone Marrow')
    end

    it 'keeps the order submitted even if recording them fails' do
      allow(OrderMailer).to receive(:supplier_changed_order).and_raise(StandardError, 'mail down')

      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result[:success]).to be(true)
      expect(order.reload.status).to eq('submitted')
    end
  end

  describe 'US Foods post-submission exception check' do
    before { allow(Rails.env).to receive(:production?).and_return(true) }

    it 'enqueues CheckOrderExceptionsJob after a live US Foods submit' do
      supplier.update!(checkout_enabled: true)
      allow(supplier).to receive(:code).and_return('usfoods')
      scraper_checkout_result.merge!(dry_run: false, confirmation_number: 'USF-1')
      allow(fake_scraper).to receive(:checkout).with(dry_run: false).and_return(scraper_checkout_result)

      expect { described_class.new(order).place_order(skip_pre_validation: true) }
        .to have_enqueued_job(CheckOrderExceptionsJob).with(order.id)
    end

    it 'does not enqueue for a non-US-Foods live submit' do
      supplier.update!(checkout_enabled: true) # code stays non-usfoods
      scraper_checkout_result.merge!(dry_run: false, confirmation_number: 'X')
      allow(fake_scraper).to receive(:checkout).and_return(scraper_checkout_result)

      expect { described_class.new(order).place_order(skip_pre_validation: true) }
        .not_to have_enqueued_job(CheckOrderExceptionsJob)
    end

    # Safety: the order is already placed before we schedule the check, so a
    # failure to enqueue must never flip a real, submitted order to failed.
    it 'keeps the order submitted even if scheduling the exception check raises' do
      supplier.update!(checkout_enabled: true)
      allow(supplier).to receive(:code).and_return('usfoods')
      scraper_checkout_result.merge!(dry_run: false, confirmation_number: 'USF-2')
      allow(fake_scraper).to receive(:checkout).with(dry_run: false).and_return(scraper_checkout_result)
      allow(CheckOrderExceptionsJob).to receive(:set).and_raise(StandardError, 'queue down')

      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result[:success]).to be true
      expect(order.reload.status).to eq('submitted')
    end
  end

  describe 'email supplier dispatch' do
    let(:supplier) { create(:supplier, :email, contact_email: 'orders@example.com') }
    let!(:credential) { nil }

    it 'routes to EmailOrderPlacementService and never instantiates a scraper' do
      email_service = instance_double(Orders::EmailOrderPlacementService, place_order: { success: true, email_sent: true })
      expect(Orders::EmailOrderPlacementService).to receive(:new).with(order).and_return(email_service)
      expect(fake_scraper_class).not_to receive(:new)

      result = described_class.new(order).place_order

      expect(result).to include(success: true, email_sent: true)
    end
  end

  describe 'missing credential' do
    it 'fails the order and raises a ValidationError when no active credential exists' do
      credential.update!(status: 'expired')

      expect {
        described_class.new(order).place_order(skip_pre_validation: true)
      }.to raise_error(Orders::OrderValidationService::ValidationError)

      expect(order.reload.status).to eq('failed')
      expect(order.error_message).to eq(
        "Not placed. EnPlace isn't connected to #{supplier.name} for this restaurant, or the login stopped working. " \
        "Reconnect #{supplier.name} under Suppliers, then resubmit."
      )
    end
  end

  describe 'cart reconciliation gate' do
    it 'reconciles the supplier cart before checkout' do
      expect(fake_scraper).to receive(:verify_cart_matches!).with(kind_of(Array)).ordered
      expect(fake_scraper).to receive(:checkout).ordered.and_return(scraper_checkout_result)

      described_class.new(order).place_order(skip_pre_validation: true)
    end

    # Regression: an orphaned line in the supplier cart (an item the chef
    # removed) must NEVER be submitted. The order halts for review instead.
    it 'halts without checking out when the cart does not match the order' do
      allow(Rails.env).to receive(:production?).and_return(true)
      supplier.update!(checkout_enabled: true)

      mismatch = Scrapers::BaseScraper::CartMismatchError.new(
        'orphaned line',
        discrepancies: [{ type: 'extra_in_cart', sku: 'NP120', cart_qty: 1 }]
      )
      allow(fake_scraper).to receive(:verify_cart_matches!).and_raise(mismatch)
      expect(fake_scraper).not_to receive(:checkout)

      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result).to include(success: false, error_type: 'cart_mismatch', requires_review: true)
      expect(result[:details][:discrepancies]).to include(hash_including(type: 'extra_in_cart', sku: 'NP120'))
      expect(order.reload.status).to eq('pending_review')
      expect(order.error_message).to include('leftover item from a previous attempt')
      expect(order.confirmation_number).to be_nil
      expect(order.submitted_at).to be_nil
    end

    # Regression — order 483 (Oct 19 2026): CW left Walnut Halves out of the
    # cart and the chef was told "a leftover item" three times, never which.
    it 'names the item the supplier left out of the cart, and places nothing' do
      supplier.update!(name: "Chef's Warehouse")
      supplier_product.update!(supplier_sku: 'nw101b', supplier_name: 'Walnut Halves', in_stock: true)
      allow(fake_scraper).to receive(:verify_cart_matches!).and_raise(
        Scrapers::BaseScraper::CartMismatchError.new(
          'missing', discrepancies: [{ type: 'missing_from_cart', sku: 'NW101B', expected_qty: 2 }]
        )
      )
      expect(fake_scraper).not_to receive(:checkout)

      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result).to include(success: false, error_type: 'items_unavailable')
      order.reload
      expect(order.status).to eq('failed')
      expect(order.error_message).to eq(
        "Not placed. Chef's Warehouse couldn't take 1 item: Walnut Halves — left out of the cart, " \
        'no reason given. Remove or change it and resubmit.'
      )
      expect(order.order_items.first.status).to eq('failed')
      expect(order.confirmation_number).to be_nil
      # No reason given is not evidence it's out of stock.
      expect(supplier_product.reload.in_stock).to be(true)
    end

    it "doesn't blame a leftover item for a quantity difference" do
      allow(fake_scraper).to receive(:verify_cart_matches!).and_raise(
        Scrapers::BaseScraper::CartMismatchError.new(
          'qty', discrepancies: [{ type: 'quantity_mismatch', sku: supplier_product.supplier_sku, cart_qty: 1, expected_qty: 2 }]
        )
      )

      described_class.new(order).place_order(skip_pre_validation: true)

      expect(order.reload.status).to eq('pending_review')
      expect(order.error_message).to eq(
        'Supplier cart did not match your order, so we did not submit it: ' \
        "#{supplier_product.supplier_name} — #{supplier.name} had 1, you ordered 2. Please review and try again."
      )
    end

    # Phase 4 (Oct 19 2026): say what differed, line by line.
    it 'words each cart difference for the chef' do
      supplier.update!(name: 'Sysco')
      supplier_product.update!(supplier_sku: 'JDE_4279592', supplier_name: 'Sugar')
      allow(fake_scraper).to receive(:verify_cart_matches!).and_raise(
        Scrapers::BaseScraper::CartMismatchError.new(
          'differs', discrepancies: [
            { type: 'uom_mismatch', sku: '4279592', cart_uom: :piece, expected_uom: :case },
            { type: 'line_count', cart_lines: 3, expected_lines: 4 },
            { type: 'total_quantity', cart_qty: 7.0, expected_qty: 8 },
            { type: 'delivery_date', cart_date: '2026-10-21', expected_date: '2026-10-22' }
          ]
        )
      )
      expect(fake_scraper).not_to receive(:checkout)

      described_class.new(order).place_order(skip_pre_validation: true)

      expect(order.reload.status).to eq('pending_review')
      expect(order.error_message).to eq(
        'Supplier cart did not match your order, so we did not submit it: ' \
        'Sugar — Sysco had it by the piece, you ordered it by the case; ' \
        "Sysco's cart had 3 item(s), your order has 4; " \
        "Sysco's cart had 7 in all, your order has 8; " \
        "Sysco's cart is for Wed Oct 21, your order is for Thu Oct 22. Please review and try again."
      )
    end

    it 'lists at most five differences' do
      allow(fake_scraper).to receive(:verify_cart_matches!).and_raise(
        Scrapers::BaseScraper::CartMismatchError.new(
          'many', discrepancies: (1..7).map { |n| { type: 'extra_in_cart', sku: "X#{n}", cart_qty: 1 } }
        )
      )

      described_class.new(order).place_order(skip_pre_validation: true)

      expect(order.reload.error_message).to include("SKU X5 — in the #{supplier.name} cart but not on your order; and 2 more.")
      expect(order.error_message).to include('leftover item from a previous attempt')
    end

    it 'skips the gate for scrapers that do not expose cart contents' do
      # A real object that genuinely does not respond to verify_cart_matches!
      # (unlike a loose double) — proves the respond_to? guard skips the gate so
      # suppliers without server-side carts (USF/WCW/PPO) are unaffected.
      result = scraper_checkout_result
      bare_scraper = Class.new do
        define_method(:clear_cart) {}
        define_method(:add_to_cart) { |*_args, **_kw| { added: [], failed: [] } }
        define_method(:checkout) { |**_kw| result }
        define_method(:close_order_browser!) {}
      end.new
      allow(fake_scraper_class).to receive(:new).with(credential).and_return(bare_scraper)

      expect(bare_scraper).not_to respond_to(:verify_cart_matches!)
      expect(described_class.new(order).place_order(skip_pre_validation: true)).to include(success: true)
    end

    # Regression — order #331 (Sep 27 2026): CW dropped Oregano at checkout's
    # price refresh. The chef must be told which item, not get a silently
    # short order.
    it 'tells the chef which item the supplier dropped at checkout and places nothing' do
      supplier_product.update!(supplier_name: 'Oregano', in_stock: true)
      dropped = Scrapers::BaseScraper::ItemUnavailableError.new(
        "Chef's Warehouse removed 1 item(s) at checkout",
        items: [{ sku: supplier_product.supplier_sku, name: 'Oregano',
                  message: "Chef's Warehouse removed this item from the cart at checkout" }]
      )
      allow(fake_scraper).to receive(:checkout).and_raise(dropped)

      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result).to include(success: false, error_type: 'items_unavailable')
      order.reload
      expect(order.status).to eq('failed')
      expect(order.error_message).to include('Oregano')
      expect(order.confirmation_number).to be_nil
      expect(order.order_items.first.notes).to include('removed this item from the cart at checkout')
      # Why CW dropped it is unknown (likely the delivery date), so the
      # catalog is not marked out of stock on this signal.
      expect(supplier_product.reload.in_stock).to be(true)
    end
  end

  # Carmin, Oct 3 2026 (order #386): an item the supplier couldn't take stops
  # the WHOLE order. It used to be deleted and the rest placed — 9 CW items
  # across 6 orders went missing behind a yellow banner.
  describe 'items the supplier could not add' do
    let(:other_product) { create(:supplier_product, supplier: supplier, supplier_name: 'Olive Oil') }

    before do
      supplier_product.update!(supplier_name: 'Juice Lemon Real', in_stock: true)
      create(:order_item, order: order, supplier_product: other_product, quantity: 1, unit_price: 50)
      allow(Rails.env).to receive(:production?).and_return(true)
      supplier.update!(checkout_enabled: true)
    end

    it 'places nothing, keeps every line, and tells the chef which item and why' do
      allow(fake_scraper).to receive(:add_to_cart).and_return(
        { added: 1, failed: [{ sku: supplier_product.supplier_sku, name: 'Juice Lemon Real', error: 'Not in order guide' }] }
      )
      expect(fake_scraper).not_to receive(:checkout)

      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result).to include(success: false, error_type: 'items_unavailable')
      order.reload
      expect(order.status).to eq('failed')
      expect(order.confirmation_number).to be_nil
      expect(order.order_items.count).to eq(2)
      expect(order.error_message).to include('Not placed', 'Juice Lemon Real — Not in order guide', 'resubmit')
      lemon = order.order_items.find_by(supplier_product: supplier_product)
      expect(lemon.status).to eq('failed')
      expect(lemon.notes).to eq('Not in order guide')
    end

    it "reads Performance's :reason key and does not mark the item out of stock on a non-stock reason" do
      allow(fake_scraper).to receive(:add_to_cart).and_return(
        { added: [], failed: [{ sku: supplier_product.supplier_sku, reason: 'HTTP 503' }] }
      )

      described_class.new(order).place_order(skip_pre_validation: true)

      expect(order.reload.error_message).to include('Juice Lemon Real — HTTP 503')
      expect(supplier_product.reload.in_stock).to be(true)
    end

    it 'does not mark the item out of stock when no reason is given' do
      allow(fake_scraper).to receive(:add_to_cart).and_return(
        { added: 1, failed: [{ sku: supplier_product.supplier_sku }] }
      )

      described_class.new(order).place_order(skip_pre_validation: true)

      expect(order.reload.status).to eq('failed')
      expect(supplier_product.reload.in_stock).to be(true)
    end

    it 'still marks it out of stock when the supplier says so' do
      allow(fake_scraper).to receive(:add_to_cart).and_return(
        { added: 1, failed: [{ sku: supplier_product.supplier_sku, error: 'Out of stock' }] }
      )

      described_class.new(order).place_order(skip_pre_validation: true)

      expect(supplier_product.reload.in_stock).to be(false)
    end
  end

  # Regression — order 483 (Oct 19 2026, D'oro), through the real CW scraper.
  # cart/add said success: true and named the line it left out only in
  # validationMessages.
  describe "Chef's Warehouse refuses a line at cart/add" do
    let(:api) { instance_double(Scrapers::ChefsWarehouseApi, ensure_session!: nil) }
    let(:cw_scraper) { Scrapers::ChefsWarehouseScraper.new(credential) }
    let(:olive_oil) { create(:supplier_product, supplier: supplier, supplier_sku: 'GO135', supplier_name: 'Olive Oil') }
    let(:empty_cart) { { 'cartGroups' => [], 'summary' => { 'totals' => {} } } }

    before do
      supplier.update!(name: "Chef's Warehouse", checkout_enabled: true)
      allow(Rails.env).to receive(:production?).and_return(true)
      supplier_product.update!(supplier_sku: 'NW101B', supplier_name: 'Walnut Halves', in_stock: true)
      create(:order_item, order: order, supplier_product: olive_oil, quantity: 1, unit_price: 50)

      allow(fake_scraper_class).to receive(:new).with(credential).and_return(cw_scraper)
      allow(cw_scraper).to receive(:api_client).and_return(api)
      allow(cw_scraper).to receive(:load_order_guide_items).and_return(
        'NW101B' => { variant_code: 'JDE_NW101B-800001', variant_metadata: {}, business_unit_id: '800001' },
        'GO135' => { variant_code: 'JDE_GO135-800001', variant_metadata: {}, business_unit_id: '800001' }
      )
      allow(api).to receive_messages(delete_cart: nil, get_cart: empty_cart, set_delivery_date: nil,
                                     refresh_cart_prices: nil, validate_cart: {}, submit_cart: nil)
      allow(api).to receive(:add_to_cart).and_return(
        { 'totalCount' => 29, 'success' => true, 'validationMessages' => ['Out of stock - (NW101B) Walnut Halves'] }
      )
    end

    it 'names the item and why, keeps every line, places nothing, and empties the cart' do
      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result).to include(success: false, error_type: 'items_unavailable')
      order.reload
      expect(order.status).to eq('failed')
      expect(order.error_message).to eq(
        "Not placed. Chef's Warehouse couldn't take 1 item: Walnut Halves — Out of stock. " \
        'Remove or change it and resubmit.'
      )
      expect(order.order_items.count).to eq(2)
      walnuts = order.order_items.find_by(supplier_product: supplier_product)
      expect(walnuts.status).to eq('failed')
      expect(walnuts.notes).to eq('Out of stock')
      expect(order.confirmation_number).to be_nil
      expect(api).not_to have_received(:submit_cart)
      # Once before adding, once after stopping.
      expect(api).to have_received(:delete_cart).twice
    end

    # The 4th attempt (17:47): two more items had gone out of stock. All of
    # them must be named and flagged, so each gets a Remove button on mobile
    # (the chef couldn't take the walnuts off with "−", which stops at 1).
    it 'names and flags every item CW refused in one go' do
      leeks = create(:supplier_product, supplier: supplier, supplier_sku: 'SW88700', supplier_name: 'Leeks')
      create(:order_item, order: order, supplier_product: leeks, quantity: 1, unit_price: 20)
      allow(cw_scraper).to receive(:load_order_guide_items).and_return(
        'NW101B' => { variant_code: 'JDE_NW101B-800001', variant_metadata: {}, business_unit_id: '800001' },
        'GO135' => { variant_code: 'JDE_GO135-800001', variant_metadata: {}, business_unit_id: '800001' },
        'SW88700' => { variant_code: 'JDE_SW88700-800001', variant_metadata: {}, business_unit_id: '800001' }
      )
      allow(api).to receive(:add_to_cart).and_return(
        { 'totalCount' => 27, 'success' => true,
          'validationMessages' => ['Out of stock - (SW88700) Leeks', 'Out of stock - (NW101B) Walnut Halves'] }
      )

      described_class.new(order).place_order(skip_pre_validation: true)

      order.reload
      expect(order.error_message).to eq(
        "Not placed. Chef's Warehouse couldn't take 2 items: Leeks — Out of stock; Walnut Halves — Out of stock. " \
        'Remove or change them and resubmit.'
      )
      expect(order.order_items.where(status: 'failed').map(&:supplier_name)).to contain_exactly('Leeks', 'Walnut Halves')
      expect(order.order_items.find_by(supplier_product: olive_oil).status).not_to eq('failed')
    end
  end

  # Phase 5 (Oct 19 2026): every stop says "Not placed", what happened and
  # what to do, in the chef's words (docs/fix-cw-out-of-stock-message.md B).
  describe 'chef-facing messages' do
    let(:name) { supplier.name }

    def pre_validation(result)
      validator = double('PreOrderValidation', validate!: { valid: true, errors: [], price_changes: [], requires_2fa: false }.merge(result))
      allow(Orders::PreOrderValidationService).to receive(:new).and_return(validator)
      described_class.new(order).place_order
    end

    it 'names and marks the items pre-order validation stopped on' do
      pre_validation(valid: false, errors: [{ type: :stock, message: "#{supplier_product.supplier_name} is out of stock (cached data)",
                                              item_id: nil, product_id: supplier_product.product_id }])

      expect(order.reload.status).to eq('failed')
      expect(order.error_message).to eq(
        "Not placed. #{name} can't supply 1 item: #{supplier_product.supplier_name} — out of stock. Remove or change it, then resubmit."
      )
      expect(order.order_items.first).to have_attributes(status: 'failed', notes: "Out of stock at #{name}")
    end

    it 'says how to reconnect when the login is not active' do
      pre_validation(valid: false, errors: [{ type: :credentials, message: "Credentials for #{name} are not active (status: expired)" }])

      expect(order.reload.error_message).to eq(
        "Not placed. EnPlace isn't connected to #{name} for this restaurant, or the login stopped working. " \
        "Reconnect #{name} under Suppliers, then resubmit."
      )
    end

    it 'lists the price changes it needs the chef to accept' do
      pre_validation(price_changes: [{ item_id: 1, product_name: 'Walnut Halves', old_price: 42.10, new_price: 45.80, difference: 3.70 }])

      expect(order.reload.status).to eq('pending_review')
      expect(order.error_message).to eq(
        "Not placed yet. #{name} prices changed on 1 item: Walnut Halves $42.10 → $45.80. " \
        'Resubmit to order at the new prices, or remove them.'
      )
    end

    it 'says NOT placed yet, and what to do, when a sign-in code is needed' do
      pre_validation(requires_2fa: true)

      expect(order.reload.status).to eq('pending_manual')
      expect(order.error_message).to start_with("Not placed yet. #{name} needs a sign-in code.")
    end

    it 'words a missed minimum with the supplier and the amounts' do
      allow(fake_scraper).to receive(:checkout)
        .and_raise(Scrapers::BaseScraper::OrderMinimumError.new('Order minimum not met', minimum: 400, current_total: 312.10))

      described_class.new(order).place_order(skip_pre_validation: true)

      expect(order.reload.error_message).to eq(
        "Not placed. #{name}'s minimum is $400.00 and this order is $312.10. Add $87.90 more, then resubmit."
      )
    end

    it "doesn't list every line when the cart call itself failed" do
      create(:order_item, order: order, supplier_product: create(:supplier_product, supplier: supplier), quantity: 1, unit_price: 5)
      allow(fake_scraper).to receive(:add_to_cart).and_return(
        added: [], failed: order.order_items.map { |i| { sku: i.supplier_product.supplier_sku, error: 'HTTP 503' } }
      )

      described_class.new(order).place_order(skip_pre_validation: true)

      expect(order.reload.error_message).to eq("Not placed. Couldn't reach #{name}'s cart, and nothing was ordered. Try again in a minute.")
    end

    it 'words a robot check and an account hold' do
      allow(fake_scraper).to receive(:checkout).and_raise(Scrapers::BaseScraper::CaptchaDetectedError, 'captcha')
      described_class.new(order).place_order(skip_pre_validation: true)
      expect(order.reload.error_message).to eq(
        "Not placed. #{name}'s site asked for a robot check EnPlace can't answer. Place this order on #{name}'s site or app."
      )

      allow(fake_scraper).to receive(:checkout).and_raise(Scrapers::BaseScraper::AccountHoldError, 'Account on credit hold.')
      described_class.new(order.reload).place_order(skip_pre_validation: true)
      expect(order.reload.error_message).to eq(
        "Not placed. #{name} has a hold on your account: Account on credit hold. Call your #{name} rep; EnPlace can't clear this."
      )
    end

    it 'starts a delivery refusal with Not placed' do
      allow(fake_scraper).to receive(:checkout)
        .and_raise(Scrapers::BaseScraper::DeliveryUnavailableError, "Sysco won't deliver on Wed Oct 7. The earliest it will is Wed Sep 30. Change the delivery date and resubmit.")

      described_class.new(order).place_order(skip_pre_validation: true)

      expect(order.reload.error_message).to start_with("Not placed. Sysco won't deliver on Wed Oct 7.")
    end
  end

  describe 'scraper exceptions' do
    it 'handles OrderMinimumError without raising' do
      err = Scrapers::BaseScraper::OrderMinimumError.new('Below minimum', minimum: 200, current_total: 20)
      allow(fake_scraper).to receive(:checkout).and_raise(err)

      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result).to include(success: false, error_type: 'order_minimum')
      expect(order.reload.status).to eq('failed')
    end

    it 'handles a generic StandardError as a failed order' do
      allow(fake_scraper).to receive(:checkout).and_raise(StandardError, 'unexpected')

      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result).to include(success: false, error_type: 'unknown')
      expect(order.reload.status).to eq('failed')
      # The technical text stays in the logs, not in front of the chef.
      expect(order.error_message).to eq(
        "Not placed. Something went wrong talking to #{supplier.name}, and nothing was ordered. " \
        "Try again; if it fails twice, order on #{supplier.name}'s site."
      )
    end

    it "shows a refusal written for chefs as it is" do
      allow(fake_scraper).to receive(:checkout)
        .and_raise(Scrapers::BaseScraper::NotPlacedError, "Couldn't read the US Foods cart, so nothing was ordered. Try again.")

      described_class.new(order).place_order(skip_pre_validation: true)

      expect(order.reload).to have_attributes(status: 'failed', error_message: "Couldn't read the US Foods cart, so nothing was ordered. Try again.")
    end

    # Phase 5 (Oct 19 2026): once the live submit went out, "failed" would
    # let the chef place the order twice.
    context 'after the scraper sent the live submit' do
      before { allow(fake_scraper).to receive(:submit_sent?).and_return(true) }

      it 'parks an unexpected error as unconfirmed' do
        allow(fake_scraper).to receive(:checkout).and_raise(NoMethodError, "undefined method `[]' for nil")

        result = described_class.new(order).place_order(skip_pre_validation: true)

        expect(result).to include(success: false, error_type: 'unconfirmed')
        expect(order.reload.status).to eq('pending_manual')
        expect(order.error_message).to eq(
          "We sent this order to #{supplier.name}, then something went wrong before it confirmed, so it may or may not " \
          "have gone through. Check #{supplier.name} before reordering, so it is not placed twice."
        )
        expect(order).not_to be_retryable
      end

      it "keeps a supplier's clear refusal as not placed" do
        allow(fake_scraper).to receive(:checkout)
          .and_raise(Scrapers::BaseScraper::NotPlacedError, 'What Chefs Want refused the order: Order minimum not met')

        result = described_class.new(order).place_order(skip_pre_validation: true)

        expect(result).to include(error_type: 'unknown')
        expect(order.reload).to have_attributes(status: 'failed', error_message: 'What Chefs Want refused the order: Order minimum not met')
      end
    end

    it 'parks an unconfirmed submit as pending_manual so it cannot be retried into a duplicate' do
      allow(fake_scraper).to receive(:checkout)
        .and_raise(Scrapers::BaseScraper::OrderUnconfirmedError, 'Check the Premiere Produce app before reordering')

      result = described_class.new(order).place_order(skip_pre_validation: true)

      expect(result).to include(success: false, error_type: 'unconfirmed')
      expect(order.reload.status).to eq('pending_manual')
      expect(order.error_message).to include('before reordering')
      expect(order).not_to be_retryable
      expect(order.confirmation_number).to be_nil
    end

    it 'closes the persistent order browser even on failure (ensure block)' do
      allow(fake_scraper).to receive(:checkout).and_raise(StandardError, 'boom')

      expect(fake_scraper).to receive(:close_order_browser!)

      described_class.new(order).place_order(skip_pre_validation: true)
    end
  end
end
