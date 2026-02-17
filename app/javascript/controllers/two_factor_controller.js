import { Controller } from "@hotwired/stimulus"
import consumer from "../channels/consumer"

export default class extends Controller {
  static targets = ["modal", "codeInput", "message", "timer", "error", "submitBtn"]
  static values = {
    sessionToken: String,
    expiresAt: String
  }

  connect() {
    this.subscription = consumer.subscriptions.create("TwoFactorChannel", {
      received: this.handleMessage.bind(this)
    })
  }

  disconnect() {
    this.subscription?.unsubscribe()
    this.stopTimer()
  }

  handleMessage(data) {
    switch(data.type) {
      case "two_fa_required":
        this.showModal(data)
        break
      case "code_result":
        this.handleCodeResult(data)
        break
      case "cancelled":
        this.hideModal()
        break
      case "error":
        this.showError(data.message)
        break
    }
  }

  showModal(data) {
    this.sessionTokenValue = data.session_token
    this.expiresAtValue = data.expires_at

    this.messageTarget.textContent = data.prompt_message
    this.modalTarget.classList.remove("hidden")
    this.codeInputTarget.value = ""
    this.codeInputTarget.focus()
    this.hideError()
    this.enableSubmit()

    this.startTimer()
    this.showNotification(data.supplier_name)
  }

  hideModal() {
    this.modalTarget.classList.add("hidden")
    this.codeInputTarget.value = ""
    this.stopTimer()
  }

  submitCode() {
    const code = this.codeInputTarget.value.trim()
    if (!code) {
      this.showError("Please enter a verification code")
      return
    }

    this.disableSubmit()
    this.submitBtnTarget.textContent = "Verifying..."

    this.subscription.perform("submit_code", {
      session_token: this.sessionTokenValue,
      code: code
    })
  }

  handleCodeResult(data) {
    this.enableSubmit()
    this.submitBtnTarget.textContent = "Verify"

    if (data.success) {
      this.hideModal()
      // Reload the page to reflect the updated state
      window.location.reload()
    } else {
      let errorMsg = data.error
      if (data.attempts_remaining) {
        errorMsg += ` (${data.attempts_remaining} attempts remaining)`
      }
      this.showError(errorMsg)
      this.codeInputTarget.value = ""
      this.codeInputTarget.focus()

      if (!data.can_retry) {
        this.disableSubmit()
        this.submitBtnTarget.textContent = "Max attempts reached"
      }
    }
  }

  cancel() {
    this.subscription.perform("cancel", {
      session_token: this.sessionTokenValue
    })
    this.hideModal()
  }

  startTimer() {
    const expiresAt = new Date(this.expiresAtValue)

    this.timerInterval = setInterval(() => {
      const now = new Date()
      const remaining = Math.max(0, Math.floor((expiresAt - now) / 1000))

      if (remaining <= 0) {
        this.timerTarget.textContent = "Expired"
        this.stopTimer()
        this.disableSubmit()
        return
      }

      const minutes = Math.floor(remaining / 60)
      const seconds = remaining % 60
      this.timerTarget.textContent = `${minutes}:${seconds.toString().padStart(2, "0")}`
    }, 1000)
  }

  stopTimer() {
    if (this.timerInterval) {
      clearInterval(this.timerInterval)
      this.timerInterval = null
    }
  }

  showError(message) {
    this.errorTarget.classList.remove("hidden")
    this.errorTarget.querySelector("p").textContent = message
  }

  hideError() {
    this.errorTarget.classList.add("hidden")
  }

  enableSubmit() {
    this.submitBtnTarget.disabled = false
  }

  disableSubmit() {
    this.submitBtnTarget.disabled = true
  }

  showNotification(supplierName) {
    if (Notification.permission === "granted") {
      new Notification("Verification Required", {
        body: `${supplierName} requires a verification code`,
        icon: "/icon.png"
      })
    } else if (Notification.permission !== "denied") {
      Notification.requestPermission()
    }
  }

  handleKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.submitCode()
    }
  }
}
