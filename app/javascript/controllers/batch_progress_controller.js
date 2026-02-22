import { Controller } from "@hotwired/stimulus"

/**
 * Polls batch placement status while any orders are "processing".
 * Updates each order card in-place with status, confirmation, errors.
 * When all orders complete, stops polling and shows the complete banner.
 *
 * Also serves as a static detail view for completed batches (no polling).
 *
 * Usage:
 *   <div data-controller="batch-progress"
 *        data-batch-progress-url-value="/order-history/batch_placement_status?batch_id=..."
 *        data-batch-progress-processing-value="true">
 *     <div data-batch-progress-target="orderCard" data-order-id="123">
 *       <span data-status-badge>Processing</span>
 *       <div data-spinner>...</div>
 *       <span data-total>$0.00</span>
 *       <div data-confirmation-wrapper class="hidden"><span data-confirmation></span></div>
 *       <div data-error-wrapper class="hidden"><span data-error></span></div>
 *     </div>
 *   </div>
 */
export default class extends Controller {
  static values = {
    url: String,
    processing: Boolean,
    interval: { type: Number, default: 3000 }
  }

  static targets = ["orderCard", "heading"]

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
    this._timer = setInterval(() => this._checkStatus(), this.intervalValue)
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

      // Update each order card in-place
      data.orders.forEach(order => {
        const card = this.orderCardTargets.find(c =>
          c.dataset.orderId == order.id
        )
        if (!card) return
        this._updateCard(card, order)
      })

      // When all done, stop polling and update UI
      if (data.all_complete) {
        this._stopPolling()
        this._showAllComplete()
      }
    } catch (e) {
      // Network error — don't stop polling, just skip this tick
      console.warn("[batch-progress] Poll failed:", e.message)
    }
  }

  _updateCard(card, order) {
    // Update status badge
    const badge = card.querySelector("[data-status-badge]")
    if (badge) {
      badge.textContent = this._statusLabel(order.status)
      badge.className = this._badgeClasses(order.status)
    }

    // Show/hide spinner
    const spinner = card.querySelector("[data-spinner]")
    if (spinner) {
      spinner.classList.toggle("hidden", !order.processing)
    }

    // Show confirmation number
    if (order.confirmation_number) {
      const conf = card.querySelector("[data-confirmation]")
      if (conf) {
        conf.textContent = order.confirmation_number
      }
      const confWrapper = card.querySelector("[data-confirmation-wrapper]")
      if (confWrapper) {
        confWrapper.classList.remove("hidden")
      }
    }

    // Show error message
    if (order.error_message) {
      const err = card.querySelector("[data-error]")
      if (err) {
        err.textContent = order.error_message
      }
      const errWrapper = card.querySelector("[data-error-wrapper]")
      if (errWrapper) {
        errWrapper.classList.remove("hidden")
      }
    }

    // Update total if available
    if (order.total_amount) {
      const total = card.querySelector("[data-total]")
      if (total) {
        total.textContent = `$${order.total_amount.toFixed(2)}`
      }
    }

    // Hide/show retry button based on status
    const retryWrapper = card.querySelector("[data-retry-wrapper]")
    if (retryWrapper) {
      retryWrapper.classList.toggle("hidden", order.status !== "failed")
    }
  }

  _statusLabel(status) {
    const labels = {
      pending: "Pending",
      processing: "Processing",
      submitted: "Submitted",
      confirmed: "Confirmed",
      dry_run_complete: "Dry Run Complete",
      failed: "Failed",
      cancelled: "Cancelled"
    }
    return labels[status] || status
  }

  _badgeClasses(status) {
    const base = "inline-flex items-center px-3 py-1 rounded-full text-sm font-medium"
    const colors = {
      pending: "bg-yellow-100 text-yellow-800",
      processing: "bg-blue-100 text-blue-800 animate-pulse",
      submitted: "bg-green-100 text-green-800",
      confirmed: "bg-green-100 text-green-800",
      dry_run_complete: "bg-purple-100 text-purple-800",
      failed: "bg-red-100 text-red-800",
      cancelled: "bg-gray-100 text-gray-800"
    }
    return `${base} ${colors[status] || "bg-gray-100 text-gray-800"}`
  }

  _showAllComplete() {
    // Hide processing banner
    const processingBanner = document.querySelector("[data-processing-banner]")
    if (processingBanner) {
      processingBanner.classList.add("hidden")
    }

    // Show complete banner
    const completeBanner = document.querySelector("[data-complete-banner]")
    if (completeBanner) {
      completeBanner.classList.remove("hidden")
    }

    // Update heading text
    if (this.hasHeadingTarget) {
      this.headingTarget.textContent = "Order Batch"
    }
  }
}
