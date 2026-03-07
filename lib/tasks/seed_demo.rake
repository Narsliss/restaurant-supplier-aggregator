# frozen_string_literal: true

desc "Seed a demo organization (Bella Vista) with 3 roles, 3 locations, products, and ~80 orders"
task seed_demo: :environment do
  puts "=== Seeding Bella Vista Restaurant Group ==="

  # ── Organisation ──────────────────────────────────────────────────
  org = Organization.find_or_create_by!(slug: "bella-vista") do |o|
    o.name      = "Bella Vista Restaurant Group"
    o.address   = "123 Main St"
    o.city      = "Miami"
    o.state     = "FL"
    o.zip_code  = "33101"
    o.phone     = "305-555-0100"
    o.timezone  = "America/New_York"
    o.complimentary = true
    o.complimentary_reason = "Demo org"
    o.max_seats = 10
  end
  puts "  Org: #{org.name} (id=#{org.id})"

  # ── Locations ─────────────────────────────────────────────────────
  locations_data = [
    { name: "Bella Vista Downtown",  address: "100 Ocean Dr",    city: "Miami", state: "FL", zip_code: "33139", phone: "305-555-0101" },
    { name: "Bella Vista Brickell",  address: "800 Brickell Ave", city: "Miami", state: "FL", zip_code: "33131", phone: "305-555-0102" },
    { name: "Bella Vista Wynwood",   address: "250 NW 26th St",  city: "Miami", state: "FL", zip_code: "33127", phone: "305-555-0103" }
  ]

  locations = locations_data.map do |ld|
    Location.find_or_create_by!(organization: org, name: ld[:name]) do |l|
      l.address  = ld[:address]
      l.city     = ld[:city]
      l.state    = ld[:state]
      l.zip_code = ld[:zip_code]
      l.phone    = ld[:phone]
    end
  end
  downtown, brickell, wynwood = locations
  puts "  Locations: #{locations.map(&:name).join(', ')}"

  # ── Users & Memberships ──────────────────────────────────────────
  users_data = [
    { email: "owner@bellavista.demo",   first: "Marco",  last: "Rossi",    role: "owner",   locs: :all },
    { email: "manager@bellavista.demo", first: "Sofia",  last: "Chen",     role: "manager", locs: [downtown, brickell] },
    { email: "chef@bellavista.demo",    first: "James",  last: "Williams", role: "chef",    locs: [downtown] }
  ]

  users = users_data.map do |ud|
    user = User.find_or_create_by!(email: ud[:email]) do |u|
      u.first_name            = ud[:first]
      u.last_name             = ud[:last]
      u.password              = "bellavista1"
      u.password_confirmation = "bellavista1"
    end
    user.update_column(:current_organization_id, org.id)
    user.update_column(:onboarding_dismissed_at, Time.current) if user.onboarding_dismissed_at.nil?

    membership = Membership.find_or_create_by!(user: user, organization: org) do |m|
      m.role = ud[:role]
    end
    membership.update_column(:role, ud[:role]) if membership.role != ud[:role]

    # Assign locations for non-owners
    if ud[:locs] != :all
      ud[:locs].each do |loc|
        MembershipLocation.find_or_create_by!(membership: membership, location: loc)
      end
    end

    puts "  User: #{user.email} (#{ud[:role]})"
    user
  end
  owner_user, manager_user, chef_user = users

  # ── Suppliers (already seeded by db:seed) ─────────────────────────
  us_foods = Supplier.find_by!(code: "usfoods")
  chefs_wh = Supplier.find_by!(code: "chefswarehouse")
  wcw      = Supplier.find_by!(code: "whatchefswant")
  suppliers = [us_foods, chefs_wh, wcw]
  puts "  Suppliers: #{suppliers.map(&:name).join(', ')}"

  # ── Supplier Credentials ──────────────────────────────────────────
  creds_data = [
    { user: owner_user,  supplier: us_foods, username: "marco.rossi@bellavista.demo" },
    { user: owner_user,  supplier: chefs_wh, username: "marco.rossi@bellavista.demo", password: "demo1234" },
    { user: chef_user,   supplier: wcw,      username: "james.w@bellavista.demo",     password: "demo1234" }
  ]

  credentials = creds_data.map do |cd|
    sc = SupplierCredential.find_or_create_by!(
      user: cd[:user], supplier: cd[:supplier], organization: org
    ) do |c|
      c.username = cd[:username]
      c.password = cd[:password] if cd[:password]
      c.status   = "active"
      c.last_login_at = 1.hour.ago
    end
    sc.update_columns(status: "active", last_login_at: 1.hour.ago) unless sc.status == "active"
    sc
  end
  puts "  Credentials: #{credentials.size} created"

  # ── Supplier Products ─────────────────────────────────────────────
  products_catalog = {
    us_foods: [
      { sku: "USF-10001", name: "USDA Choice Ribeye Steak 12oz",    price: 18.95, pack: "6ct",   unit: "case" },
      { sku: "USF-10002", name: "Atlantic Salmon Fillet 8oz",       price: 12.50, pack: "8ct",   unit: "case" },
      { sku: "USF-10003", name: "Chicken Breast Boneless 6oz",      price: 42.00, pack: "40ct",  unit: "case" },
      { sku: "USF-10004", name: "Ground Beef 80/20 5lb",            price: 28.75, pack: "4pk",   unit: "case" },
      { sku: "USF-10005", name: "Baby Back Ribs Full Rack",         price: 35.50, pack: "4ct",   unit: "case" },
      { sku: "USF-10006", name: "Jumbo Shrimp 16/20 Peeled",       price: 14.95, pack: "2lb",   unit: "bag" },
      { sku: "USF-10007", name: "Heavy Cream 36%",                  price: 8.50,  pack: "1qt",   unit: "each" },
      { sku: "USF-10008", name: "Unsalted Butter 1lb",              price: 5.25,  pack: "36ct",  unit: "case" },
      { sku: "USF-10009", name: "Parmigiano Reggiano Wedge",        price: 22.00, pack: "5lb",   unit: "each" },
      { sku: "USF-10010", name: "Fresh Mozzarella Ball",            price: 6.75,  pack: "3lb",   unit: "each" },
      { sku: "USF-10011", name: "San Marzano Tomatoes #10",         price: 7.25,  pack: "6ct",   unit: "case" },
      { sku: "USF-10012", name: "Extra Virgin Olive Oil",           price: 32.00, pack: "1gal",  unit: "each" },
      { sku: "USF-10013", name: "Arborio Rice",                     price: 18.50, pack: "10lb",  unit: "bag" },
      { sku: "USF-10014", name: "00 Flour Caputo",                  price: 24.00, pack: "55lb",  unit: "bag" },
      { sku: "USF-10015", name: "Mixed Baby Greens",                price: 16.00, pack: "3lb",   unit: "case" },
      { sku: "USF-10016", name: "Roma Tomatoes",                    price: 22.50, pack: "25lb",  unit: "case" },
      { sku: "USF-10017", name: "Yellow Onions",                    price: 14.00, pack: "50lb",  unit: "bag" },
      { sku: "USF-10018", name: "Garlic Peeled",                    price: 12.50, pack: "5lb",   unit: "bag" },
      { sku: "USF-10019", name: "Fresh Basil",                      price: 8.00,  pack: "1lb",   unit: "each" },
      { sku: "USF-10020", name: "Balsamic Vinegar Modena",          price: 15.00, pack: "500ml", unit: "each" }
    ],
    chefs_warehouse: [
      { sku: "CW-20001", name: "A5 Wagyu Strip Loin",              price: 125.00, pack: "2lb",   unit: "each" },
      { sku: "CW-20002", name: "Diver Scallops U10",               price: 38.50,  pack: "5lb",   unit: "case" },
      { sku: "CW-20003", name: "Foie Gras Torchon",                price: 65.00,  pack: "1lb",   unit: "each" },
      { sku: "CW-20004", name: "Duck Breast Moulard",              price: 28.00,  pack: "4ct",   unit: "case" },
      { sku: "CW-20005", name: "Lamb Rack Frenched",               price: 42.00,  pack: "2ct",   unit: "case" },
      { sku: "CW-20006", name: "Black Truffle Whole",              price: 95.00,  pack: "2oz",   unit: "each" },
      { sku: "CW-20007", name: "Saffron Threads Grade 1",          price: 18.00,  pack: "1g",    unit: "each" },
      { sku: "CW-20008", name: "Aged Gruyere 12mo",                price: 24.50,  pack: "5lb",   unit: "wheel" },
      { sku: "CW-20009", name: "Burrata Fresh",                    price: 9.50,   pack: "8oz",   unit: "each" },
      { sku: "CW-20010", name: "Prosciutto di Parma 24mo",         price: 32.00,  pack: "3lb",   unit: "each" },
      { sku: "CW-20011", name: "Wild Mushroom Mix",                price: 22.00,  pack: "2lb",   unit: "case" },
      { sku: "CW-20012", name: "Microgreens Assorted",             price: 12.00,  pack: "4oz",   unit: "each" },
      { sku: "CW-20013", name: "Vanilla Bean Madagascar",          price: 28.00,  pack: "10ct",  unit: "pack" },
      { sku: "CW-20014", name: "Valrhona Chocolate 70%",           price: 35.00,  pack: "6.6lb", unit: "block" },
      { sku: "CW-20015", name: "Edible Flowers Mixed",             price: 14.00,  pack: "50ct",  unit: "box" },
      { sku: "CW-20016", name: "Truffle Oil Black",                price: 16.50,  pack: "250ml", unit: "each" },
      { sku: "CW-20017", name: "Aged Balsamic 25yr",               price: 45.00,  pack: "100ml", unit: "each" },
      { sku: "CW-20018", name: "Lobster Tail 6oz",                 price: 18.00,  pack: "10ct",  unit: "case" },
      { sku: "CW-20019", name: "Osso Buco Veal Shank",             price: 32.00,  pack: "4ct",   unit: "case" },
      { sku: "CW-20020", name: "Mascarpone",                       price: 8.50,   pack: "2lb",   unit: "tub" }
    ],
    what_chefs_want: [
      { sku: "WCW-30001", name: "Heirloom Tomato Mix",             price: 28.00, pack: "10lb",  unit: "case" },
      { sku: "WCW-30002", name: "Baby Arugula Organic",            price: 14.00, pack: "2lb",   unit: "case" },
      { sku: "WCW-30003", name: "Meyer Lemons",                    price: 18.00, pack: "10lb",  unit: "case" },
      { sku: "WCW-30004", name: "Fresh Figs Black Mission",        price: 24.00, pack: "flat",  unit: "flat" },
      { sku: "WCW-30005", name: "Avocado Hass #48",                price: 52.00, pack: "48ct",  unit: "case" },
      { sku: "WCW-30006", name: "Asparagus Jumbo",                 price: 32.00, pack: "11lb",  unit: "case" },
      { sku: "WCW-30007", name: "Fingerling Potatoes",             price: 16.50, pack: "10lb",  unit: "case" },
      { sku: "WCW-30008", name: "Chanterelle Mushrooms",           price: 38.00, pack: "2lb",   unit: "case" },
      { sku: "WCW-30009", name: "Rainbow Chard Bunch",             price: 3.50,  pack: "1bu",   unit: "bunch" },
      { sku: "WCW-30010", name: "Fennel Bulb",                     price: 2.75,  pack: "1ea",   unit: "each" },
      { sku: "WCW-30011", name: "Shallots",                        price: 12.00, pack: "5lb",   unit: "bag" },
      { sku: "WCW-30012", name: "Fresh Thyme",                     price: 4.50,  pack: "4oz",   unit: "each" },
      { sku: "WCW-30013", name: "Radicchio",                       price: 18.00, pack: "12ct",  unit: "case" },
      { sku: "WCW-30014", name: "Celery Root",                     price: 14.00, pack: "6ct",   unit: "case" },
      { sku: "WCW-30015", name: "Blood Oranges",                   price: 22.00, pack: "18lb",  unit: "case" },
      { sku: "WCW-30016", name: "Fresh Horseradish",               price: 8.00,  pack: "2lb",   unit: "each" },
      { sku: "WCW-30017", name: "Kabocha Squash",                  price: 16.00, pack: "35lb",  unit: "case" },
      { sku: "WCW-30018", name: "Purple Sweet Potatoes",           price: 20.00, pack: "20lb",  unit: "case" },
      { sku: "WCW-30019", name: "Fresh Turmeric Root",             price: 10.00, pack: "1lb",   unit: "each" },
      { sku: "WCW-30020", name: "Watermelon Radish",               price: 12.00, pack: "5lb",   unit: "bag" }
    ]
  }

  supplier_products = {}
  products_catalog.each do |supplier_key, items|
    supplier = case supplier_key
               when :us_foods       then us_foods
               when :chefs_warehouse then chefs_wh
               when :what_chefs_want then wcw
               end

    supplier_products[supplier.id] = items.map do |item|
      SupplierProduct.find_or_create_by!(supplier: supplier, supplier_sku: item[:sku]) do |sp|
        sp.supplier_name  = item[:name]
        sp.current_price  = item[:price]
        sp.pack_size      = item[:pack]
        sp.price_unit     = item[:unit]
        sp.in_stock       = true
        sp.last_scraped_at = 2.hours.ago
        sp.price_updated_at = 1.day.ago
      end
    end
  end
  puts "  Products: #{supplier_products.values.flatten.size} total"

  # ── Supplier Lists (order guides) ─────────────────────────────────
  lists_config = [
    { credential: credentials[0], name: "US Foods Order Guide",       supplier: us_foods, products: supplier_products[us_foods.id][0..11], location: downtown },
    { credential: credentials[1], name: "Chef's Warehouse Favorites", supplier: chefs_wh, products: supplier_products[chefs_wh.id][0..9],  location: downtown },
    { credential: credentials[2], name: "WCW Produce Guide",          supplier: wcw,      products: supplier_products[wcw.id][0..12],       location: downtown }
  ]

  lists_config.each do |lc|
    list = SupplierList.find_or_create_by!(
      supplier_credential: lc[:credential],
      supplier: lc[:supplier],
      name: lc[:name]
    ) do |sl|
      sl.organization = org
      sl.location     = lc[:location]
      sl.list_type    = "order_guide"
      sl.sync_status  = "synced"
      sl.last_synced_at = 3.hours.ago
      sl.product_count  = lc[:products].size
    end

    lc[:products].each_with_index do |sp, idx|
      SupplierListItem.find_or_create_by!(supplier_list: list, sku: sp.supplier_sku) do |sli|
        sli.supplier_product = sp
        sli.name       = sp.supplier_name
        sli.price      = sp.current_price
        sli.pack_size  = sp.pack_size
        sli.price_unit = sp.price_unit
        sli.quantity   = 1
        sli.in_stock   = true
        sli.position   = idx
      end
    end
  end
  puts "  Supplier lists: #{lists_config.size} with items"

  # ── Orders ────────────────────────────────────────────────────────
  # Skip if orders already exist for this org (idempotent)
  if org.orders.count >= 50
    puts "  Orders: #{org.orders.count} already exist — skipping"
  else
    # Clear any partial seed
    org.orders.where("created_at > ?", 9.weeks.ago).destroy_all if org.orders.count > 0 && org.orders.count < 50

    rng = Random.new(42) # deterministic randomness
    statuses_pool = (%w[submitted] * 7 + %w[confirmed] * 5 + %w[pending] * 2 + %w[verifying price_changed] * 1 + %w[failed] * 1)
    order_count = 0

    # Define order distribution: [weeks_ago_range, count, amount_range]
    order_waves = [
      # Prior month — lighter (gives positive % change)
      { period: (7.weeks.ago.beginning_of_week)..(5.weeks.ago.end_of_week), count: 15, amount: 280..950 },
      # Middle weeks — moderate
      { period: (4.weeks.ago.beginning_of_week)..(3.weeks.ago.end_of_week), count: 18, amount: 350..1200 },
      # Recent 2 weeks — heavy
      { period: (2.weeks.ago.beginning_of_week)..(1.week.ago.end_of_week),  count: 22, amount: 400..1500 },
      # Current week — active
      { period: Time.current.beginning_of_week..Time.current,                count: 12, amount: 500..1800 }
    ]

    # User/location/supplier combos to distribute orders across
    order_combos = [
      { user: owner_user,   location: downtown, supplier: us_foods,  products: supplier_products[us_foods.id] },
      { user: owner_user,   location: brickell, supplier: us_foods,  products: supplier_products[us_foods.id] },
      { user: owner_user,   location: wynwood,  supplier: us_foods,  products: supplier_products[us_foods.id] },
      { user: owner_user,   location: downtown, supplier: chefs_wh,  products: supplier_products[chefs_wh.id] },
      { user: owner_user,   location: brickell, supplier: chefs_wh,  products: supplier_products[chefs_wh.id] },
      { user: manager_user, location: downtown, supplier: us_foods,  products: supplier_products[us_foods.id] },
      { user: manager_user, location: brickell, supplier: us_foods,  products: supplier_products[us_foods.id] },
      { user: manager_user, location: downtown, supplier: chefs_wh,  products: supplier_products[chefs_wh.id] },
      { user: chef_user,    location: downtown, supplier: wcw,       products: supplier_products[wcw.id] },
      { user: chef_user,    location: downtown, supplier: us_foods,  products: supplier_products[us_foods.id] }
    ]

    order_waves.each do |wave|
      wave[:count].times do |i|
        combo = order_combos[rng.rand(order_combos.size)]
        status = statuses_pool[rng.rand(statuses_pool.size)]
        created = wave[:period].begin + rng.rand((wave[:period].end - wave[:period].begin).to_i).seconds
        has_savings = rng.rand(10) < 4 # 40% chance

        # Build delivery date for non-failed orders
        delivery = nil
        if %w[submitted confirmed pending verifying].include?(status)
          delivery = created.to_date + rng.rand(1..5).days
          # For current week, set some deliveries in the future
          delivery = Date.current + rng.rand(1..4).days if wave == order_waves.last && rng.rand(2) == 0
        end

        order = Order.create!(
          user:         combo[:user],
          organization: org,
          location:     combo[:location],
          supplier:     combo[:supplier],
          status:       status,
          created_at:   created,
          updated_at:   created,
          delivery_date: delivery,
          submitted_at: %w[submitted confirmed].include?(status) ? created + 5.minutes : nil,
          confirmed_at: status == "confirmed" ? created + 30.minutes : nil,
          savings_amount: has_savings ? rng.rand(5.0..50.0).round(2) : 0
        )

        # Add 3-8 order items
        num_items = rng.rand(3..8)
        item_products = combo[:products].sample(num_items, random: rng)
        subtotal = 0

        item_products.each do |sp|
          qty = rng.rand(1..6)
          price = sp.current_price * (0.95 + rng.rand * 0.1) # slight price variance
          price = price.round(2)
          line = (qty * price).round(2)
          subtotal += line

          order.order_items.create!(
            supplier_product: sp,
            quantity: qty,
            unit_price: price,
            line_total: line,
            status: %w[failed cancelled].include?(status) ? "failed" : "added"
          )
        end

        tax = (subtotal * 0.07).round(2)
        order.update_columns(subtotal: subtotal, tax: tax, total_amount: subtotal + tax)
        order_count += 1
      end
    end

    puts "  Orders: #{order_count} created with items"
  end

  # ── Summary ───────────────────────────────────────────────────────
  puts "\n=== Bella Vista Demo Org Ready ==="
  puts "  Login credentials (password: bellavista1):"
  puts "    Owner:   owner@bellavista.demo"
  puts "    Manager: manager@bellavista.demo"
  puts "    Chef:    chef@bellavista.demo"
  puts "  Org: #{org.name} (#{org.locations.count} locations)"
  puts "  Orders: #{org.orders.count} total"
  puts "  This month spend: $#{'%.2f' % org.orders.where('created_at >= ?', Time.current.beginning_of_month).sum(:total_amount)}"
end
