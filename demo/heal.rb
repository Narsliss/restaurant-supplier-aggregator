# frozen_string_literal: true

module DemoMode
  # Puts the demo's own database back into a state the screens can show:
  # frees what the missing worker left stuck, keeps every saved login a
  # placeholder, and keeps the sample data looking current. Writes only demo
  # rows. Runs on the first request after boot and then once a day (the demo
  # has no scheduler), in the background.
  module Heal
    @mutex = Mutex.new
    @last_run_on = nil

    class << self
      attr_reader :last_run_on

      def run_once_today
        return unless DemoMode.enabled?

        @mutex.synchronize do
          return if @last_run_on == Date.current

          @last_run_on = Date.current
        end
        Thread.new { Rails.application.executor.wrap { run! } }
      end

      def run!
        return unless DemoMode.enabled?

        Rails.logger.info '[DemoMode] Heal starting'
        steps = %i[scrub_logins scrub_email_suppliers checkout_off free_lists free_orders close_2fa_requests
                   clear_job_queue freshen_catalog freshen_delivery_dates freshen_orders]
        steps.each do |step|
          send(step)
        rescue StandardError => e
          Rails.logger.error "[DemoMode] Heal #{step} failed: #{e.class}: #{e.message}"
        end
        Rails.logger.info '[DemoMode] Heal done'
      end

      # Every saved login becomes a placeholder: no real username, password,
      # session or trusted-device token can survive on the demo. The new values
      # are encrypted on a fresh record and written over the old columns, so a
      # login encrypted under another key (a copied database) can't stop it.
      def scrub_logins
        SupplierCredential.includes(:supplier, :organization).find_each do |cred|
          scrub_secrets(cred)
          cred.update_columns(
            status: cred.status == 'hold' ? 'hold' : 'active', last_error: nil, refresh_failures: 0,
            two_fa_enabled: false, importing: false, import_progress: 0, import_total: 0,
            import_status_text: nil, last_login_at: Time.current
          )
        end
      end

      # Also used the moment someone connects a login on the demo: whatever
      # they typed (possibly a real supplier password) is never kept.
      def scrub_secrets(cred)
        fresh = SupplierCredential.new(
          username: placeholder_username(cred),
          password: cred.supplier&.password_required? ? 'demo-password' : nil,
          session_data: '{"demo":true}'
        )
        cred.update_columns(
          encrypted_username: fresh.encrypted_username, encrypted_username_iv: fresh.encrypted_username_iv,
          encrypted_password: fresh.encrypted_password, encrypted_password_iv: fresh.encrypted_password_iv,
          encrypted_session_data: fresh.encrypted_session_data,
          encrypted_session_data_iv: fresh.encrypted_session_data_iv,
          trusted_device_token: nil, trusted_device_expires_at: nil
        )
      end

      def placeholder_username(cred)
        org = cred.organization&.name.to_s.parameterize.split('-').first(2).join
        "orders@#{org.presence || 'restaurant'}.demo"
      end

      # Email suppliers show their order address on the Suppliers page; on the
      # demo it is a placeholder, never a real person's inbox.
      def scrub_email_suppliers
        Supplier.where(auth_type: 'email').find_each do |supplier|
          supplier.update_columns(contact_email: "orders@#{supplier.name.parameterize.delete('-').presence || 'supplier'}.demo")
        end
      end

      def checkout_off
        Supplier.update_all(checkout_enabled: false)
      end

      def free_lists
        AggregatedList.where(match_status: 'matching').find_each do |list|
          list.update!(match_status: list.product_matches.exists? ? 'matched' : 'pending')
        end
        AggregatedList.where(catalog_search_status: 'searching').update_all(catalog_search_status: 'completed')
      end

      def free_orders
        Order.where(status: 'verifying').pluck(:id).each { |id| Simulator.verify_prices(id) }
        Order.where(status: 'processing').pluck(:id).each { |id| Simulator.place_order(id) }
      end

      def close_2fa_requests
        Supplier2faRequest.where(status: %w[pending submitted]).update_all(status: 'expired')
      end

      # Jobs queued for a worker the demo never had. If a worker were ever
      # attached by mistake, this backlog (real supplier jobs) must not be there.
      def clear_job_queue
        SolidQueue::Job.delete_all
      end

      def freshen_catalog
        SupplierProduct.where('last_scraped_at IS NULL OR last_scraped_at < ?', 1.day.ago)
                       .update_all(last_scraped_at: Time.current)
      end

      # Sysco/Performance always publish delivery days; any other login that
      # has stored days (the live demo's all held August's) gets fresh ones
      # too, or the builder offers dates that have passed. A login with none
      # stored keeps none: no restriction.
      def freshen_delivery_dates
        api = SupplierCredential.joins(:supplier).where(suppliers: { code: %w[sysco performance] })
        stored = SupplierCredential.where("available_delivery_dates <> '[]'::jsonb")
        SupplierCredential.where(id: api.select(:id)).or(SupplierCredential.where(id: stored.select(:id)))
                          .pluck(:id).each { |id| Simulator.fetch_delivery_dates(id) }
      end

      SHIFTED_ORDER_COLUMNS = %w[created_at updated_at submitted_at confirmed_at delivery_date price_verified_at
                                 draft_saved_at received_at exceptions_checked_at submit_sent_at].freeze

      # Move each organization's placed orders forward so its newest one is
      # today: the dashboards' "this month" and "last 30 days" stay populated.
      # Only placed orders (what dashboards and reports count) move; a failed
      # or draft order keeps its date, so an old failure never comes back as
      # this week's "NOT placed" alarm.
      def freshen_orders
        placed = Order.where(status: Order::KPI_STATUSES)
        placed.group(:organization_id).maximum(:created_at).each do |org_id, newest|
          days = (Date.current - newest.to_date).to_i
          next if days < 1

          shift = SHIFTED_ORDER_COLUMNS.map { |c| "#{c} = #{c} + INTERVAL '#{days} days'" }.join(', ')
          placed.where(organization_id: org_id).update_all(shift)
          Rails.logger.info "[DemoMode] Moved organization #{org_id}'s placed orders forward #{days} days"
        end
      end
    end

    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        Heal.run_once_today
        @app.call(env)
      end
    end
  end
end
