module Suppliers
  # The one-time "which of your restaurants is this?" step for an owner's or
  # manager's multi-restaurant supplier login. Chefs never get here.
  class RestaurantMatching
    Result = Struct.new(:ok, :error, keyword_init: true)

    def initialize(credential)
      @credential = credential
    end

    def self.eligible?(credential)
      credential.switchable_supplier? &&
        %w[owner manager].include?(credential.user&.role_in(credential.organization))
    end

    # Live list from the supplier: [{ id:, name:, meta: }]. Also remembers how
    # many there are, so the suppliers page only offers matching when useful.
    def restaurants
      api = @credential.supplier.scraper_klass.new(@credential).api_client
      list = RestaurantSwitcher.list_restaurants(@credential, api)
      @credential.update_columns(supplier_restaurant_count: list.size)
      list
    end

    # At credential validation: remember the login's restaurants and link them
    # automatically when certain (RestaurantAutoLinker). Owners/managers with
    # 2+ restaurants only; best effort, never raises.
    def self.record_count(credential)
      RestaurantAutoLinker.run_safely(credential)
    end

    # assignments: { supplier_account_id => location_id or "" }, restaurants:
    # the live list (for names / division numbers). Replaces all matches.
    def save(assignments, restaurants)
      by_id = restaurants.index_by { |r| r[:id].to_s }
      chosen = assignments.to_h.transform_keys(&:to_s).reject { |_, loc| loc.blank? }

      return Result.new(ok: false, error: "Match this connection's own restaurant (#{@credential.location&.name})") \
        unless chosen.values.map(&:to_i).include?(@credential.location_id)
      return Result.new(ok: false, error: 'Each location can only be matched to one restaurant') \
        if chosen.values.map(&:to_i).uniq.size != chosen.size
      return Result.new(ok: false, error: 'Unknown restaurant') unless (chosen.keys - by_id.keys).empty?

      SupplierCredentialRestaurant.transaction do
        @credential.restaurants.destroy_all
        # Home first: other links require it (SupplierCredentialRestaurant).
        chosen.sort_by { |_, loc| loc.to_i == @credential.location_id ? 0 : 1 }.each do |account_id, location_id|
          r = by_id[account_id]
          @credential.restaurants.create!(
            location_id: location_id.to_i,
            supplier_account_id: account_id,
            account_name: r[:name],
            account_meta: r[:meta] || {}
          )
        end
      end
      Result.new(ok: true)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    # "Stop switching": back to a single-restaurant connection.
    def clear!
      @credential.restaurants.destroy_all
    end
  end
end
