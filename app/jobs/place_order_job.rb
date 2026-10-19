class PlaceOrderJob < ApplicationJob
  queue_as :critical

  # One in-flight placement per order. Prevents duplicate supplier
  # submissions from double-clicks, batch-submit races, or stale
  # retry jobs landing after a successful submission.
  limits_concurrency to: 1, key: ->(order_id, *) { "place_order_#{order_id}" }, duration: 15.minutes

  discard_on ActiveRecord::RecordNotFound

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

    Rails.logger.info "[PlaceOrderJob] Processing order #{order.id} for #{order.supplier.name}"

    started_at = Time.current
    service = Orders::OrderPlacementService.new(order)
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
  end

  private

  # Something escaped OrderPlacementService. A placed or cancelled order is
  # never touched (this rescue once flipped submitted order 102 to failed),
  # nor is an outcome the service already wrote during this run (a named
  # refusal, "no connection"). Otherwise the order is still "processing", or
  # untouched since the job started (a 2FA retry): if the live submit had
  # gone out the supplier may have the order, so unconfirmed, never failed.
  def record_crash(order, service, started_at)
    order.reload
    return if order.completed? || order.cancelled?

    settled = !order.processing? && started_at && order.updated_at >= started_at
    unless settled
      if service&.submit_sent?
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
