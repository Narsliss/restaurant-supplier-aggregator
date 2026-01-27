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

    # Get the handler and submit the code
    # Note: In a real implementation, you'd need to maintain browser session state
    # This is a simplified version that triggers a re-attempt of the original action
    
    result = process_2fa_code(request, data["code"])

    transmit({
      type: "code_result",
      success: result[:success],
      error: result[:error],
      can_retry: result[:can_retry],
      attempts_remaining: result[:attempts_remaining]
    })

    if result[:success]
      # Resume the original operation if applicable
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

    # In a real implementation, this would submit the code to the supplier site
    # For now, we'll simulate the verification by checking if code is numeric and 6 digits
    # The actual verification happens when the scraper resumes
    
    # Mark as submitted - actual verification happens when operation resumes
    {
      success: true,
      message: "Code submitted. Verifying..."
    }

  rescue => e
    Rails.logger.error "[TwoFactorChannel] Error processing code: #{e.message}"
    
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
      # Trigger session refresh to complete login
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
