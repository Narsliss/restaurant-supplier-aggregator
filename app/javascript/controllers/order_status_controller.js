import { Controller } from "@hotwired/stimulus"

/**
 * Polls the order's placement status while it's "processing".
 * When the status changes (success, failure, dry_run, etc.),
 * refreshes the page via Turbo to show the final result.
 *
 * Usage:
 *   <div data-controller="order-status"
 *        data-order-status-url-value="/orders/123/placement_status"
 *        data-order-status-processing-value="true">
 */
export default class extends Controller {
  static values = {
    url: String,
    processing: Boolean,
    interval: { type: Number, default: 3000 }
  }

  connect() {
    if (this.processingValue) {
      this._startPolling()
    }
  }

  disconnect() {
    this._stopPolling()
  }

  // --- Private ---

  _startPolling() {
    // Show a subtle loading indicator
    this._showProcessingUI()

    this._timer = setInterval(() => {
      this._checkStatus()
    }, this.intervalValue)

    // Also check immediately
    this._checkStatus()
  }

  _stopPolling() {
    if (this._timer) {
      clearInterval(this._timer)
      this._timer = null
    }
  }

  async _checkStatus() {
    try {
      const response = await fetch(this.urlValue, {
        headers: { "Accept": "application/json" }
      })

      if (!response.ok) return

      const data = await response.json()

      if (!data.processing) {
        // Order is no longer processing — refresh the page to show final state
        this._stopPolling()

        // Use Turbo to seamlessly replace the page content
        if (window.Turbo) {
          window.Turbo.visit(window.location.href, { action: "replace" })
        } else {
          window.location.reload()
        }
      }
    } catch (e) {
      // Network error — don't stop polling, just skip this tick
      console.warn("[order-status] Poll failed:", e.message)
    }
  }

  _showProcessingUI() {
    // Find the status badge and add a pulse animation
    const badge = this.element.querySelector("[data-order-status-badge]")
    if (badge) {
      badge.classList.add("animate-pulse")
    }
  }
}
