module Authentication
  class TwoFactorHandler
    class TwoFactorRequired < StandardError
      attr_reader :request_id, :two_fa_type, :prompt_message, :session_token

      def initialize(request_id:, two_fa_type:, prompt_message:, session_token:)
        @request_id = request_id
        @two_fa_type = two_fa_type
        @prompt_message = prompt_message
        @session_token = session_token
        super("Two-factor authentication required")
      end
    end

    attr_reader :credential, :browser, :operation_type

    TIMEOUT_MINUTES = 5
    MAX_ATTEMPTS = 3

    def initialize(credential, browser, operation_type: "login")
      @credential = credential
      @browser = browser
      @operation_type = operation_type
    end

    def two_fa_required?
      detect_2fa_prompt.present?
    end

    def initiate_2fa_flow
      prompt_info = detect_2fa_prompt
      return nil unless prompt_info

      # Create 2FA request record
      request = Supplier2faRequest.create!(
        user: credential.user,
        supplier_credential: credential,
        request_type: operation_type,
        two_fa_type: prompt_info[:type].to_s,
        prompt_message: prompt_info[:message],
        status: "pending",
        expires_at: TIMEOUT_MINUTES.minutes.from_now
      )

      # Update credential to indicate 2FA is enabled
      credential.update!(two_fa_enabled: true, two_fa_type: prompt_info[:type].to_s)

      # Notify user that 2FA is needed
      notify_user_2fa_required(request)

      # Raise exception to pause automation
      raise TwoFactorRequired.new(
        request_id: request.id,
        two_fa_type: prompt_info[:type],
        prompt_message: prompt_info[:message],
        session_token: request.session_token
      )
    end

    def submit_code(request, code)
      return { success: false, error: "Request expired" } if request.expired?
      return { success: false, error: "Max attempts exceeded", can_retry: false } if request.attempts >= MAX_ATTEMPTS

      request.record_attempt!(code)

      # Submit code to supplier site
      result = enter_2fa_code(code)

      if result[:success]
        request.mark_verified!
        save_trusted_device_if_available
        { success: true }
      else
        if request.attempts >= MAX_ATTEMPTS
          request.mark_failed!
          { success: false, error: "Max attempts exceeded", can_retry: false }
        else
          { 
            success: false, 
            error: result[:error], 
            can_retry: true, 
            attempts_remaining: MAX_ATTEMPTS - request.attempts 
          }
        end
      end
    end

    def cancel(request)
      request.mark_cancelled!
    end

    private

    def detect_2fa_prompt
      indicators = {
        sms: [
          "input[name*='sms']",
          "input[name*='phone_code']",
          ".sms-verification",
          "[data-testid='sms-code-input']",
          "#smsCode"
        ],
        totp: [
          "input[name*='totp']",
          "input[name*='authenticator']",
          ".authenticator-code",
          "[data-testid='totp-input']",
          "#totpCode"
        ],
        email: [
          "input[name*='email_code']",
          ".email-verification",
          "[data-testid='email-code-input']",
          "#emailCode"
        ],
        generic: [
          "input[name*='verification_code']",
          "input[name*='2fa']",
          "input[name*='mfa']",
          ".two-factor-input",
          ".verification-code-input",
          "#verificationCode",
          "input[name*='otp']",
          ".otp-input"
        ]
      }

      indicators.each do |type, selectors|
        selectors.each do |selector|
          element = browser.at_css(selector)
          if element
            message = extract_2fa_message
            return { type: type, selector: selector, message: message }
          end
        end
      end

      # Check for 2FA page by content
      page_text = browser.body&.text&.downcase || ""
      two_fa_keywords = [
        "enter.*code",
        "verification.*code",
        "two.?factor",
        "2fa",
        "authenticator",
        "one.?time.*password",
        "otp",
        "security.*code"
      ]

      if two_fa_keywords.any? { |keyword| page_text.match?(/#{keyword}/i) }
        input = browser.at_css("input[type='text'], input[type='tel'], input[type='number']")
        if input
          return { type: :unknown, selector: nil, message: extract_2fa_message }
        end
      end

      nil
    end

    def extract_2fa_message
      message_selectors = [
        ".verification-message",
        ".two-factor-instructions",
        ".mfa-prompt",
        "label[for*='code']",
        ".form-description",
        "p.instructions",
        ".otp-message",
        ".code-prompt"
      ]

      message_selectors.each do |selector|
        element = browser.at_css(selector)
        return element.text.strip if element&.text.present?
      end

      "Please enter your verification code"
    end

    def enter_2fa_code(code)
      # Find the code input field
      input_selectors = [
        "input[name*='code']",
        "input[name*='2fa']",
        "input[name*='verification']",
        ".verification-code-input input",
        ".otp-input",
        "input[type='tel']",
        "input[autocomplete='one-time-code']"
      ]

      input = nil
      input_selectors.each do |selector|
        input = browser.at_css(selector)
        break if input
      end

      unless input
        return { success: false, error: "Could not find code input field" }
      end

      # Clear and enter code
      input.focus
      input.type(code, :clear)

      # Find and click submit button
      submit_selectors = [
        "button[type='submit']",
        "input[type='submit']",
        ".verify-button",
        ".submit-code",
        ".btn-verify",
        "[data-action='verify']"
      ]

      submit_selectors.each do |selector|
        submit = browser.at_css(selector)
        if submit
          submit.click
          break
        end
      end

      # Wait for result
      sleep 2

      # Check if we're past the 2FA screen
      if two_fa_required?
        # Still on 2FA screen - check for error message
        error = browser.at_css(".error-message, .alert-danger, .invalid-code, .error")&.text&.strip
        { success: false, error: error || "Invalid code" }
      else
        { success: true }
      end
    end

    def save_trusted_device_if_available
      # Check if there's a "remember this device" checkbox
      remember_checkbox = browser.at_css(
        "input[name*='remember'], input[name*='trust'], #rememberDevice, .trust-device input"
      )

      if remember_checkbox && !remember_checkbox.checked?
        remember_checkbox.click
      end

      # After successful 2FA, capture any trusted device token from cookies
      trusted_cookie = browser.cookies.all.find { |name, _| name.match?(/trusted|remember|device/i) }

      if trusted_cookie
        credential.update!(
          trusted_device_token: trusted_cookie[1].value,
          trusted_device_expires_at: 30.days.from_now
        )
      end
    end

    def notify_user_2fa_required(request)
      # Broadcast to user's browser via ActionCable
      TwoFactorChannel.broadcast_to(
        credential.user,
        {
          type: "two_fa_required",
          request_id: request.id,
          session_token: request.session_token,
          supplier_name: credential.supplier.name,
          two_fa_type: request.two_fa_type,
          prompt_message: request.prompt_message,
          expires_at: request.expires_at.iso8601
        }
      )

      # Also queue email/push notification as backup
      TwoFactorNotificationJob.perform_later(request.id)
    end
  end
end
