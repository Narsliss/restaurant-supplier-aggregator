class PlaceOrderJob < ApplicationJob
  queue_as :critical

  # One in-flight placement per order. Prevents duplicate supplier
  # submissions from double-clicks, batch-submit races, or stale
  # retry jobs landing after a successful submission.
  #
  # Solid Queue bypasses this on a deploy (it re-queues the running job), so
  # it is not what stops a double order: the account lock and the order's
  # submit marker are (docs/plan-order-placement-double-submit-and-account-lock.md).
  limits_concurrency to: 1, key: ->(order_id, *) { "place_order_#{order_id}" }, duration: 15.minutes

  discard_on ActiveRecord::RecordNotFound

  # Another placement holds this order's supplier account: try again this
  # often, and give up (nothing sent) after this long, before the 15-minute
  # "stuck" bar (Order::STUCK_PROCESSING_AFTER).
  ACCOUNT_RETRY_WAIT = 20.seconds
  ACCOUNT_WAIT_LIMIT = 10.minutes

  def perform(order_id, options = {})
    order = Order.find(order_id)

    if order.completed?
      Rails.logger.info "[PlaceOrderJob] Order #{order.id} already #{order.status}, skipping"
      return
    end

    # Demo mode: simulate successful submission without browser automation
    if ENV['DEMO_MODE'] == 'true'
      order.update!(status: 'submitted', submitted_at: Time.current)
      Rails.logger.info "[PlaceOrderJob] Order #{order.id} demo-submitted for #{order.supplier.name}"
      notify_owner(order)
      return
    end

    # One placement at a time per supplier account (shared carts), taken
    # before anything — pre-order checks included — touches the supplier.
    account_lock = Orders::SupplierAccountLock.for(order)
    return wait_for_supplier_account(order, options) unless account_lock.acquire

    # Whoever held the lock may just have placed, cancelled or sent it.
    order.reload
    return unless still_to_place?(order)

    Rails.logger.info "[PlaceOrderJob] Processing order #{order.id} for #{order.supplier.name}"

    started_at = Time.current
    service = Orders::OrderPlacementService.new(order, account_lock: account_lock)
    result = service.place_order(
      accept_price_changes: options[:accept_price_changes] || false,
      skip_warnings: options[:skip_warnings] || false
    )

    if result[:success]
      if result[:dry_run]
        # Dry run — no real order placed, don't send confirmation email
        Rails.logger.info "[PlaceOrderJob] Order #{order.id} DRY RUN complete for #{order.supplier.name} (checkout not enabled)"
      else
        # Real order placed — notify owner
        notify_owner(order)
        Rails.logger.info "[PlaceOrderJob] Order #{order.id} placed successfully"
      end
    else
      handle_failure(order, result)
      alert_not_placed(order, result)
    end
  rescue ActiveRecord::RecordNotFound
    raise # let `discard_on` handle missing orders cleanly
  rescue => e
    Rails.logger.error "[PlaceOrderJob] Order #{order_id} failed: #{e.class}: #{e.message}"

    record_crash(order, service, started_at) if order

    raise # Re-raise for retry logic
  ensure
    # After record_crash, so a crash is written down before the next
    # placement on this account can start.
    account_lock&.release
  end

  private

  # Read under the account lock. A cancelled order is never placed (a batch
  # order waits 15 s per order ahead of it in the queue, and the chef can
  # cancel it meanwhile). An order whose live submit already went out is
  # never sent again: a deploy re-queues the running job, and the first run
  # may have died after the supplier took the order but before we wrote
  # "submitted".
  def still_to_place?(order)
    if order.completed? || order.cancelled?
      Rails.logger.info "[PlaceOrderJob] Order #{order.id} already #{order.status}, skipping"
      return false
    end
    return true unless order.submit_sent_recorded?

    if order.processing?
      Rails.logger.error "[PlaceOrderJob] Order #{order.id}: a live submit went out at #{order.submit_sent_at} " \
                         "and was never settled — NOT sending it again"
      order.update!(status: 'pending_manual', error_message: Orders::OrderPlacementService.unconfirmed_message(order))
      alert_not_placed(order, { error_type: 'unconfirmed' })
    else
      Rails.logger.warn "[PlaceOrderJob] Order #{order.id} (#{order.status}) was already sent once; leaving it as it is"
    end
    false
  end

  # Another placement holds the account. Free this thread and try again
  # shortly; after ACCOUNT_WAIT_LIMIT stop the order, with nothing sent.
  def wait_for_supplier_account(order, options)
    waiting_since = Time.zone.at(options[:account_wait_since] || Time.current.to_i)

    if Time.current - waiting_since < ACCOUNT_WAIT_LIMIT
      Rails.logger.info "[PlaceOrderJob] Order #{order.id}: another #{order.supplier.name} order on this account is " \
                        "being placed; trying again in #{ACCOUNT_RETRY_WAIT.inspect}"
      self.class.set(wait: ACCOUNT_RETRY_WAIT)
          .perform_later(order.id, options.merge(account_wait_since: waiting_since.to_i))
      return
    end

    order.reload
    return unless still_to_place?(order) && order.processing?

    name = order.supplier&.name || 'the supplier'
    Rails.logger.warn "[PlaceOrderJob] Order #{order.id}: #{name} account still busy after #{ACCOUNT_WAIT_LIMIT.inspect}, giving up"
    order.update!(status: 'failed',
                  error_message: "Not placed. Another #{name} order for this restaurant or login was still going through, " \
                                 'so nothing was sent. Try again in a few minutes.')
    alert_not_placed(order)
  end

  # Something escaped OrderPlacementService. A placed or cancelled order is
  # never touched (this rescue once flipped submitted order 102 to failed),
  # nor is an outcome the service already wrote during this run (a named
  # refusal, "no connection"). Otherwise the order is still "processing", or
  # untouched since the job started (a 2FA retry): if the live submit had
  # gone out the supplier may have the order, so unconfirmed, never failed.
  def record_crash(order, service, started_at)
    order.reload
    return if order.completed? || order.cancelled?
    # Sent by an earlier run and settled there (unconfirmed, or clearly
    # refused): this run sent nothing, so it has nothing to record.
    return if order.submit_sent_recorded? && !order.processing? && !service&.submit_sent?

    settled = !order.processing? && started_at && order.updated_at >= started_at
    unless settled
      if service&.submit_sent? || order.submit_sent_recorded?
        order.update!(status: "pending_manual", error_message: Orders::OrderPlacementService.unconfirmed_message(order))
        return alert_not_placed(order, { error_type: "unconfirmed" })
      end

      name = order.supplier&.name || "the supplier"
      order.update!(status: "failed",
                    error_message: "Not placed. Something went wrong before anything was sent to #{name}. " \
                                   "Try again; if it fails twice, order on #{name}'s site.")
    end
    alert_not_placed(order)
  rescue StandardError => e
    Rails.logger.error "[PlaceOrderJob] Could not record the failure of order #{order&.id}: #{e.class}: #{e.message}"
  end

  # Email the chef + owner(s) if she doesn't see the failure in the app
  # (OrderFailureAlertJob). Swallows everything: this runs inside perform's
  # broad rescue, and alerting must never change an order's state.
  def alert_not_placed(order, result = {})
    order.reload
    return unless OrderFailureAlertJob::NOT_PLACED_STATUSES.include?(order.status)

    kind = result[:error_type] == 'unconfirmed' ? 'unconfirmed' : 'not_placed'
    OrderFailureAlertJob.schedule(order, kind: kind)
  rescue StandardError => e
    Rails.logger.error "[PlaceOrderJob] Could not schedule not-placed alert for order #{order&.id}: #{e.class}: #{e.message}"
  end

  # Notify org owner(s) when a non-owner team member places an order
  def notify_owner(order)
    return if order.user == order.organization.owner
    OrderMailer.order_placed_notification(order).deliver_later
  rescue => e
    Rails.logger.warn "[PlaceOrderJob] Owner notification failed for order #{order.id}: #{e.message}"
  end

  def handle_failure(order, result)
    case result[:error_type]
    when "2fa_required"
      Rails.logger.info "[PlaceOrderJob] Order #{order.id} waiting for 2FA"
    when "price_changed"
      Rails.logger.info "[PlaceOrderJob] Order #{order.id} requires price review"
    when "captcha"
      Rails.logger.warn "[PlaceOrderJob] Order #{order.id} blocked by CAPTCHA"
    when "account_hold"
      Rails.logger.warn "[PlaceOrderJob] Order #{order.id} blocked by account hold"
    else
      Rails.logger.error "[PlaceOrderJob] Order #{order.id} failed: #{result[:error]}"
    end
  end
end
