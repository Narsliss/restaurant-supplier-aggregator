module Suppliers
  # Points a multi-restaurant supplier login (an owner's one login that can
  # order for several of their restaurants) at the restaurant matched to an
  # EnPlace location, CONFIRMS the supplier really switched, runs the block,
  # then switches back to the connection's home restaurant.
  #
  #   Suppliers::RestaurantSwitcher.new(credential, scraper.api_client).with_restaurant(order.location_id) do
  #     ...cart / checkout / list scrape...
  #   end
  #
  # A connection with NO restaurant matches (every chef, every single-restaurant
  # login) passes straight through: no calls, no lock, unchanged behaviour.
  #
  # The switch sticks at the supplier until something switches it back, so work
  # for a location always switches deliberately first — never trusting where
  # the login was left. A per-connection advisory lock keeps a sync from
  # switching the login to another restaurant in the middle of an order.
  #
  # Mechanics per supplier: docs/owner-multi-location-findings.md.
  class RestaurantSwitcher
    class MismatchError < Scrapers::BaseScraper::ScrapingError; end
    class UnsupportedSupplierError < StandardError; end

    LOCK_NAMESPACE = 72_310 # arbitrary, fixed: "supplier credential switch" advisory locks

    ADAPTERS = {
      'usfoods' => lambda { |api|
        {
          switch: ->(r) { api.switch_customer!(r.supplier_account_id, r.account_meta['division_number']) },
          current: -> { api.token_customer_number }
        }
      },
      'chefswarehouse' => lambda { |api|
        {
          switch: ->(r) { api.ensure_session! && api.set_organization!(r.supplier_account_id) },
          current: -> { api.current_ship_to }
        }
      },
      'whatchefswant' => lambda { |api|
        {
          switch: ->(r) { api.switch_company!(r.supplier_account_id) },
          current: -> { api.current_company_id }
        }
      },
      'premiereproduceone' => lambda { |api|
        {
          switch: ->(r) { api.select_restaurant!(r.supplier_account_id) },
          current: -> { api.current_restaurant_uuid }
        }
      }
    }.freeze

    attr_reader :credential

    # `api_or_scraper`: the API client the caller will use for the block, or a
    # scraper exposing #api_client — the switch must act on the same client.
    def initialize(credential, api_or_scraper)
      @credential = credential
      @api_or_scraper = api_or_scraper
    end

    # Resolved only when a switch actually happens, so a connection without
    # matches never even has its API client built here.
    def api
      @api ||= @api_or_scraper.respond_to?(:api_client) ? @api_or_scraper.api_client : @api_or_scraper
    end

    def with_restaurant(location)
      enter(location)
      yield
    ensure
      leave
    end

    # Non-block form for flows already shaped as begin/ensure (order placement):
    # call #enter before touching the supplier, #leave in the ensure.
    # Returns false (and does nothing) when the connection has no match for
    # `location` — every single-restaurant connection.
    def enter(location)
      @target = credential.restaurant_for(location)
      unless @target
        return false unless credential.multi_restaurant?

        # A linked login asked to work for a restaurant it isn't linked to:
        # refuse rather than run wherever the login was last left.
        raise MismatchError, "#{credential.supplier&.name} login isn't linked to that restaurant — stopped before doing anything"
      end

      lock!
      @home = credential.home_restaurant
      switch_and_confirm!(@target)
      true
    rescue StandardError
      if @locked
        switch_back(@home) if @home && @home.id != @target&.id
        unlock!
      end
      raise
    end

    def leave
      return unless @locked

      begin
        switch_back(@home) if @home && @target && @home.id != @target.id
      ensure
        unlock!
      end
    end

    # Restaurants the login can pick from: [{ id:, name:, street:, city:, zip:, meta: }].
    # Holds the connection's switch lock: refreshing a session saves the
    # login's current context, which must not interleave with a switched order.
    def self.list_restaurants(credential, api)
      raise UnsupportedSupplierError, credential.supplier&.code unless ADAPTERS.key?(credential.supplier&.code)

      conn = SupplierCredential.connection
      conn.execute("SELECT pg_advisory_lock(#{LOCK_NAMESPACE}, #{credential.id.to_i})")
      begin
        api.ensure_session!
        api.list_restaurants
      ensure
        conn.execute("SELECT pg_advisory_unlock(#{LOCK_NAMESPACE}, #{credential.id.to_i})")
      end
    end

    def switch_and_confirm!(restaurant)
      adapter[:switch].call(restaurant)
      current = adapter[:current].call.to_s
      return true if current == restaurant.supplier_account_id.to_s

      raise MismatchError,
            "#{credential.supplier.name} is on restaurant #{current.presence || 'unknown'}, " \
            "not #{restaurant.account_name || restaurant.supplier_account_id} — stopped before doing anything"
    end

    private

    def adapter
      builder = ADAPTERS[credential.supplier&.code]
      raise UnsupportedSupplierError, credential.supplier&.code unless builder

      @adapter ||= builder.call(api)
    end

    def switch_back(home)
      switch_and_confirm!(home)
    rescue StandardError => e
      # Never mask the block's own outcome. Everything that uses this login for
      # a location switches deliberately first, so a failed return home cannot
      # misroute an order — but say so loudly.
      Rails.logger.error "[RestaurantSwitcher] Could not switch #{credential.supplier&.name} connection " \
                         "#{credential.id} back to its home restaurant: #{e.class} #{e.message}"
    end

    def lock!
      SupplierCredential.connection.execute("SELECT pg_advisory_lock(#{LOCK_NAMESPACE}, #{credential.id.to_i})")
      @locked = true
    end

    def unlock!
      return unless @locked

      SupplierCredential.connection.execute("SELECT pg_advisory_unlock(#{LOCK_NAMESPACE}, #{credential.id.to_i})")
      @locked = false
    end
  end
end
