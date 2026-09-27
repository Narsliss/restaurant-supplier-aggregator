module Suppliers
  # Links the restaurants on an owner's (or manager's) one supplier login to
  # their EnPlace restaurants automatically — no matching screen. Carmin, Sep 27
  # 2026: "asking them to match locations to logins seems insane … do something
  # smart with addresses". Runs at connect, when a restaurant is added, and daily.
  #
  # A supplier restaurant is linked only when exactly ONE of the owner's
  # restaurants agrees, by any of:
  #   * street number + 5-digit zip (never city: suppliers disagree on it);
  #   * the restaurant saved on a chef's own single-restaurant login for the
  #     same supplier at that restaurant (US Foods customer, PPO restaurant,
  #     WCW location) — how PPO's D'oro, which has no street, gets linked;
  #   * Chef's Warehouse only (its list has no addresses): exact name,
  #     ignoring case and punctuation.
  # Anything uncertain stays unlinked for the one-click fix. Links are one to
  # one, existing links are never changed, and nothing links until the login's
  # own (home) restaurant is linked — a login with links always switches, so
  # its home restaurant must be one of them. Success is silent.
  class RestaurantAutoLinker
    Result = Struct.new(:restaurants, :linked, keyword_init: true)

    def self.eligible?(credential)
      org = credential.organization
      RestaurantMatching.eligible?(credential) && org.present? && org.locations.count > 1
    end

    # Best effort for background callers: never raises.
    def self.run_safely(credential)
      new(credential).call
    rescue StandardError => e
      Rails.logger.warn "[RestaurantAutoLinker] credential #{credential.id}: #{e.class} #{e.message}"
      nil
    end

    attr_reader :credential

    # dry_run: report what would be linked, save nothing.
    def initialize(credential, dry_run: false, restaurants: nil)
      @credential = credential
      @dry_run = dry_run
      @restaurants = restaurants
    end

    def call
      return nil unless self.class.eligible?(credential)

      list = (@restaurants || fetch_restaurants).map { |r| r.to_h.symbolize_keys }
      remember(list) unless @dry_run
      proposals = list.size > 1 ? propose(list) : {}
      link!(proposals, list) unless @dry_run || proposals.empty?
      Result.new(restaurants: list, linked: proposals)
    end

    # { supplier_account_id => location_id } — certain, one-to-one, new links only.
    def propose(list)
      existing = credential.restaurants.pluck(:supplier_account_id, :location_id).to_h
      # Never a restaurant (or supplier account) the owner's other connection
      # for this supplier already covers — see RestaurantLinks.
      standing = RestaurantLinks.new(credential, locations)
      free = locations.reject { |l| existing.value?(l.id) || standing.sibling_location_ids.include?(l.id) }
      proposed = list.reject { |r| existing.key?(r[:id].to_s) || standing.sibling_accounts.include?(r[:id].to_s) }
                     .to_h { |r| [r[:id].to_s, certain_location(r, free)] }
                     .compact

      # One-to-one: a restaurant claimed twice is uncertain for both.
      claimed = proposed.values.tally
      proposed.reject! { |_, loc| claimed[loc] > 1 }

      home = credential.location_id
      home_linked = existing.value?(home) || proposed.value?(home)
      home_linked ? proposed : {}
    end

    private

    def fetch_restaurants
      api = credential.supplier.scraper_klass.new(credential).api_client
      RestaurantSwitcher.list_restaurants(credential, api)
    end

    def remember(list)
      credential.update_columns(
        supplier_restaurants: list.map { |r| r.slice(:id, :name, :street, :city, :zip, :meta).transform_keys(&:to_s) },
        supplier_restaurant_count: list.size,
        supplier_restaurants_checked_at: Time.current
      )
    end

    def link!(proposals, list)
      by_id = list.index_by { |r| r[:id].to_s }
      SupplierCredentialRestaurant.transaction do
        # Home first: other links require it (SupplierCredentialRestaurant).
        proposals.sort_by { |_, loc| loc == credential.location_id ? 0 : 1 }.each do |account_id, location_id|
          r = by_id[account_id]
          credential.restaurants.create!(location_id: location_id, supplier_account_id: account_id,
                                         account_name: r[:name], account_meta: r[:meta] || {})
        end
      end
      Rails.logger.info "[RestaurantAutoLinker] credential #{credential.id}: linked #{proposals.size} restaurant(s)"
      ImportSupplierListsJob.perform_later(credential.id, force: true)
    end

    def certain_location(restaurant, candidates)
      found = candidates.select do |loc|
        address_match?(restaurant, loc) || chef_login_match?(restaurant, loc) || name_match?(restaurant, loc)
      end
      found.one? ? found.first.id : nil
    end

    def address_match?(restaurant, loc)
      key = RestaurantAddress.key(restaurant[:street], restaurant[:zip])
      key.present? && key == RestaurantAddress.key(loc.address, loc.zip_code)
    end

    def name_match?(restaurant, loc)
      return false unless credential.supplier.code == 'chefswarehouse'

      name = RestaurantAddress.normalized_name(restaurant[:name])
      name.present? && name == RestaurantAddress.normalized_name(loc.name)
    end

    def chef_login_match?(restaurant, loc)
      ids = chef_login_accounts[loc.id]
      return false if ids.blank?

      ids.include?(restaurant[:id].to_s) ||
        Array(restaurant.dig(:meta, 'location_ids') || restaurant.dig(:meta, :location_ids)).any? { |id| ids.include?(id.to_s) }
    end

    # { location_id => [account ids] } saved on single-restaurant logins for
    # this supplier in the organization (chefs' own connections). Logins with
    # restaurant links are skipped: their saved account moves when they switch.
    def chef_login_accounts
      @chef_login_accounts ||= SupplierCredential
                               .where(organization_id: credential.organization_id, supplier_id: credential.supplier_id)
                               .where.not(id: credential.id)
                               .where.not(id: SupplierCredentialRestaurant.select(:supplier_credential_id))
                               .each_with_object(Hash.new { |h, k| h[k] = [] }) do |c, acc|
                                 id = saved_account_id(c)
                                 acc[c.location_id] << id if id && c.location_id
                               end
    end

    def saved_account_id(cred)
      data = cred.session_data
      data = (JSON.parse(data) rescue {}) if data.is_a?(String)
      data ||= {}
      value = case cred.supplier.code
              when 'usfoods' then data.dig('api_tokens', 'auth_context', 'customer_number')
              when 'premiereproduceone' then data.dig('api_tokens', 'restaurant_uuid')
              when 'whatchefswant' then data.dig('api_context', 'location_id')
              end
      value.presence&.to_s
    rescue StandardError
      nil
    end

    def locations
      @locations ||= begin
        membership = credential.user.membership_for(credential.organization)
        membership ? membership.assigned_locations.to_a : []
      end
    end
  end
end
