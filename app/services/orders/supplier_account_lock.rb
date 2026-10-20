require 'zlib'

module Orders
  # One order placement at a time per supplier account (Oct 20 2026,
  # docs/plan-order-placement-double-submit-and-account-lock.md).
  #
  # Supplier carts are shared wider than one order: US Foods empties every
  # open order of the customer, Premiere Produce keeps one draft per
  # restaurant, Chef's Warehouse submits whatever the login's cart holds. So
  # two placements that share a restaurant at a supplier, or a supplier login,
  # must not overlap. Two keys, both from local data (no supplier calls):
  #
  #   restaurant: supplier + the order's location (two logins at one restaurant)
  #   login:      supplier + the login's username (one login, several restaurants
  #               or several connection rows)
  #
  # Postgres session advisory locks: a worker that dies drops them at once, so
  # a killed deploy never leaves an account locked. Never waits — PlaceOrderJob
  # tries again later instead of holding one of the critical queue's threads —
  # so it can't deadlock with RestaurantSwitcher's lock, always taken after it.
  class SupplierAccountLock
    NAMESPACE = 72_311 # next to Suppliers::RestaurantSwitcher::LOCK_NAMESPACE (72_310)

    attr_reader :names

    # The login is the one placement will use (the same query as
    # OrderPlacementService#get_active_credential). None: the restaurant key
    # alone; placement then fails "not connected" anyway.
    def self.for(order)
      new(order, Suppliers::OrderCredential.scope(order).take)
    end

    def initialize(order, credential)
      @names = ["restaurant:#{order.supplier_id}:#{order.location_id || 'none'}"]
      username = credential&.username.to_s.strip.downcase
      @names << "login:#{order.supplier_id}:#{username}" if username.present?
      @held = []
    end

    # Takes every key or none. false when another placement holds one.
    # Session locks belong to the connection that takes them: the job's own.
    def acquire(connection: ApplicationRecord.connection)
      @connection = connection
      keys.each do |key|
        unless try_lock(key)
          release
          return false
        end
        @held << key
      end
      true
    end

    # Still held by this connection? Rails can reconnect a dropped connection
    # without telling us, and a reconnect loses session locks.
    def held?
      return false if @held.empty?

      held = query(<<~SQL.squish, :select_values).map(&:to_i)
        SELECT objid FROM pg_locks
        WHERE locktype = 'advisory' AND granted AND pid = pg_backend_pid()
          AND classid = #{NAMESPACE} AND objsubid = 2
      SQL
      @held.all? { |key| held.include?(key & 0xFFFF_FFFF) }
    rescue StandardError => e
      Rails.logger.error "[SupplierAccountLock] Could not check #{names.inspect}: #{e.class}: #{e.message}"
      false
    end

    def release
      @held.reverse_each do |key|
        released = query("SELECT pg_advisory_unlock(#{NAMESPACE}, #{key})")
        Rails.logger.error "[SupplierAccountLock] #{names.inspect} was no longer held when released" unless released
      rescue StandardError => e
        Rails.logger.error "[SupplierAccountLock] Could not release #{names.inspect}: #{e.class}: #{e.message}"
      end
      @held = []
    end

    private

    # Signed 32-bit keys, in a fixed order. A hash collision only adds waiting.
    def keys
      @keys ||= names.map { |name| [Zlib.crc32(name)].pack('L').unpack1('l') }.uniq.sort
    end

    def try_lock(key)
      query("SELECT pg_try_advisory_lock(#{NAMESPACE}, #{key})")
    end

    # Jobs run with the query cache on, which would answer a repeated lock or
    # unlock SELECT from memory without asking Postgres.
    def query(sql, method = :select_value)
      @connection.uncached { @connection.public_send(method, sql) }
    end
  end
end
