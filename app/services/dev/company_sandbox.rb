# Dev-only harness for repeatedly testing onboarding AS A CHEF OWNER.
#
# Philosophy (Carmin, Aug 2026): the point of each test run is to feel the
# REAL experience — live credential connection, live scraping, real matching
# and seeding, real wall-clock waits. So spawn() does NOT fake any of that.
# It only removes the paperwork that isn't under test:
#   - user signup form            -> owner account created, login printed
#   - company/restaurant forms    -> org + location pre-filled
#   - Stripe checkout             -> active sandbox subscription row
#   - "invite a team member" gate -> one pending invitation
# From there YOU log in and connect real supplier credentials like any chef.
#
#   Dev::CompanySandbox.spawn(name: "Test Kitchen")   # bare company, live flow
#   Dev::CompanySandbox.timeline(org)                 # how long did each step take?
#   Dev::CompanySandbox.list / teardown(org) / teardown_all
#
# spawn(clone_from: some_location) exists for pipeline iteration WITHOUT live
# scraping (clones that location's lists through the real import service) —
# it is explicitly a shortcut and prints itself as such.
#
# Never available in production. Sandbox orgs are tagged by name prefix and
# teardown refuses to touch anything else.
module Dev
  class CompanySandbox
    PREFIX = 'SANDBOX'.freeze
    PASSWORD = 'Sandbox1234!'.freeze

    StubScraper = Struct.new(:lists) do
      def scrape_lists = lists
    end

    class << self
      def guard!
        raise 'Dev::CompanySandbox is not available in production' if Rails.env.production?
      end

      def spawn(name:, clone_from: nil, suppliers: nil, match: true)
        guard!

        slug = "#{PREFIX.downcase}-#{name.parameterize}-#{Time.current.strftime('%H%M%S')}"

        owner = User.create!(
          email: "#{slug}@test.local",
          password: PASSWORD,
          first_name: 'Sandbox',
          last_name: name.titleize,
          role: 'user'
        )

        org = Organization.create!(
          name: "#{PREFIX} #{name}",
          slug: slug,
          address: '1 Test St', city: 'Testville', state: 'OH', zip_code: '45202'
        )
        membership = org.memberships.create!(user: owner, role: 'owner')
        owner.update!(current_organization: org)

        location = org.locations.create!(
          name: name.titleize, user: owner,
          address: '1 Test St', city: 'Testville', state: 'OH', zip_code: '45202'
        )
        membership.membership_locations.create!(location: location)

        # Bypass ONLY the paperwork gates: Stripe + the team-invite step.
        Subscription.create!(
          user: owner, organization: org,
          stripe_subscription_id: "sub_#{slug}",
          status: 'active'
        )
        org.organization_invitations.create!(
          email: "chef-#{slug}@test.local", role: 'chef', invited_by: owner, location: location
        )

        summary = {
          org_id: org.id,
          org_name: org.name,
          login: owner.email,
          password: PASSWORD,
          location_id: location.id,
          mode: clone_from ? 'CLONED (pipeline shortcut — not a live-experience test)' : 'LIVE (connect real supplier credentials in the UI)'
        }

        summary.merge!(clone_lists!(org, owner, location, clone_from, suppliers, match)) if clone_from
        summary
      end

      # The patience report: everything that happened to this org, with
      # elapsed time since creation. Run after (or during) a live test to
      # answer "was this worth a chef owner's wait?".
      def timeline(org)
        guard!
        t0 = org.created_at
        events = [[t0, 'company created']]

        SupplierCredential.where(organization_id: org.id).includes(:supplier).find_each do |c|
          events << [c.created_at, "#{c.supplier.name}: credential connected"]
        end
        SupplierList.where(organization: org).includes(:supplier).find_each do |sl|
          events << [sl.created_at, "#{sl.supplier.name}: list \"#{sl.name}\" imported (#{sl.product_count || sl.supplier_list_items.count} items)"]
          events << [sl.last_synced_at, "#{sl.supplier.name}: \"#{sl.name}\" synced"] if sl.last_synced_at
        end
        AggregatedList.where(organization: org).find_each do |al|
          events << [al.updated_at, "matched list \"#{al.name}\": #{al.match_status} (#{al.product_matches.count} lines)"]
        end
        OrderList.where(organization: org).where.not(seed_supplier_id: nil).find_each do |ol|
          events << [ol.seeded_at, "seeded order list \"#{ol.name}\" (#{ol.order_list_items.count} items)"]
        end

        events.compact.sort_by(&:first).map do |at, label|
          elapsed = (at - t0).to_i
          format('+%02d:%02d  %s', elapsed / 60, elapsed % 60, label)
        end
      end

      def list
        guard!
        Organization.where('name LIKE ?', "#{PREFIX} %").order(:created_at)
      end

      # Destroys the org, its data, and any users who belonged only to it.
      def teardown(org)
        guard!
        raise ArgumentError, "refusing to destroy non-sandbox org '#{org.name}'" unless org.name.start_with?("#{PREFIX} ")

        orphan_user_ids = org.memberships.pluck(:user_id).select do |uid|
          Membership.where(user_id: uid).where.not(organization_id: org.id).none?
        end

        org.organization_invitations.destroy_all
        User.where(current_organization_id: org.id).update_all(current_organization_id: nil)
        org.destroy!
        User.where(id: orphan_user_ids, role: 'user').find_each(&:destroy!)
        true
      end

      def teardown_all
        guard!
        list.to_a.each { |org| teardown(org) }.size
      end

      private

      # Pipeline shortcut: clone a template location's lists through the REAL
      # ImportSupplierListsService (stub scraper), then match inline. Useful
      # for iterating on import/matching/seeding code without live scraping —
      # NOT for judging the chef experience.
      def clone_lists!(org, owner, location, template_location, suppliers, match)
        template_lists = template_location.supplier_lists.includes(:supplier, :supplier_list_items)
                                          .group_by(&:supplier)
        template_lists.select! { |s, _| suppliers.include?(s.name) } if suppliers

        imported = {}
        template_lists.each do |supplier, lists|
          credential = SupplierCredential.create!(
            user: owner, supplier: supplier, organization_id: org.id, location_id: location.id,
            username: owner.email, password: 'sandbox-not-real', status: 'active'
          )

          payload = lists.map do |sl|
            {
              remote_id: sl.remote_list_id, name: sl.name, list_type: sl.list_type,
              url: sl.remote_list_url,
              items: sl.supplier_list_items.order(:position).map do |sli|
                { sku: sli.sku, name: sli.name, price: sli.price, price_unit: sli.price_unit,
                  pack_size: sli.pack_size, quantity: sli.quantity, in_stock: sli.read_attribute(:in_stock),
                  position: sli.position, remote_item_id: sli.remote_item_id }
              end
            }
          end

          result = ImportSupplierListsService.new(credential).call(scraper: StubScraper.new(payload))
          imported[supplier.name] = result.slice(:lists_synced, :items_imported)
        end

        matched_list = AggregatedList.find_by(organization: org, location_id: location.id,
                                              list_type: %w[master matched])
        SyncNewProductsJob.perform_now(matched_list.id) if match && matched_list

        {
          matched_list_id: matched_list&.id,
          imported: imported,
          seeded_order_lists: OrderList.for_location(location).where.not(seed_supplier_id: nil).pluck(:name)
        }
      end
    end
  end
end
