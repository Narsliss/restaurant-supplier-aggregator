class TwoFactorChannel < ApplicationCable::Channel
  def subscribed
    stream_for current_user
  end

  def unsubscribed
    # Cleanup when channel is unsubscribed
  end

  def submit_code(data)
    request = Supplier2faRequest.find_by(
      session_token: data["session_token"],
      user: current_user
    )

    unless request
      transmit({ type: "error", message: "Invalid or expired request" })
      return
    end

    unless request.active?
      transmit({ type: "error", message: "Request has expired or been processed" })
      return
    end

    result = process_2fa_code(request, data["code"])

    transmit({
      type: "code_result",
      success: result[:success],
      error: result[:error],
      can_retry: result[:can_retry],
      attempts_remaining: result[:attempts_remaining]
    })

    if result[:success]
      resume_operation(request)
    end
  end

  def cancel(data)
    request = Supplier2faRequest.find_by(
      session_token: data["session_token"],
      user: current_user
    )

    request&.mark_cancelled!
    transmit({ type: "cancelled" })
  end

  private

  def process_2fa_code(request, code)
    return { success: false, error: "Request expired", can_retry: false } if request.expired?
    return { success: false, error: "Max attempts exceeded", can_retry: false } if request.attempts >= Supplier2faRequest::MAX_ATTEMPTS

    request.record_attempt!(code)

    # Get the scraper for this supplier and attempt login with the 2FA code
    credential = request.supplier_credential
    scraper = credential.supplier.scraper_klass.new(credential)

    if scraper.respond_to?(:login_with_code)
      result = scraper.login_with_code(code)

      if result[:success]
        request.mark_verified!
        { success: true, message: "Verification successful" }
      else
        if request.attempts >= Supplier2faRequest::MAX_ATTEMPTS
          request.mark_failed!
          { success: false, error: result[:error] || "Verification failed", can_retry: false }
        else
          {
            success: false,
            error: result[:error] || "Invalid code",
            can_retry: true,
            attempts_remaining: Supplier2faRequest::MAX_ATTEMPTS - request.attempts
          }
        end
      end
    else
      # Scraper doesn't support login_with_code — fall back to marking as submitted
      # and letting the resume operation handle it
      request.mark_verified!
      { success: true, message: "Code submitted. Verifying..." }
    end

  rescue Scrapers::BaseScraper::AuthenticationError => e
    Rails.logger.error "[TwoFactorChannel] Auth error during 2FA: #{e.message}"
    if request.attempts >= Supplier2faRequest::MAX_ATTEMPTS
      request.mark_failed!
      { success: false, error: e.message, can_retry: false }
    else
      {
        success: false,
        error: "Login failed after code entry: #{e.message}",
        can_retry: true,
        attempts_remaining: Supplier2faRequest::MAX_ATTEMPTS - request.attempts
      }
    end
  rescue => e
    Rails.logger.error "[TwoFactorChannel] Error processing code: #{e.message}"
    Rails.logger.error e.backtrace&.first(5)&.join("\n")

    if request.attempts >= Supplier2faRequest::MAX_ATTEMPTS
      request.mark_failed!
      { success: false, error: "Max attempts exceeded", can_retry: false }
    else
      {
        success: false,
        error: "Verification failed. Please try again.",
        can_retry: true,
        attempts_remaining: Supplier2faRequest::MAX_ATTEMPTS - request.attempts
      }
    end
  end

  def resume_operation(request)
    case request.request_type
    when "login"
      # Login already completed by login_with_code — just refresh session state
      RefreshSessionJob.perform_later(request.supplier_credential_id)
    when "checkout"
      # Find and resume the pending order
      order = current_user.orders.find_by(status: "pending_manual", supplier: request.supplier_credential.supplier)
      PlaceOrderJob.perform_later(order.id) if order
    when "price_refresh"
      # Resume price scraping
      ScrapeSupplierJob.perform_later(request.supplier_credential.supplier_id, request.supplier_credential_id)
    end
  end
end
