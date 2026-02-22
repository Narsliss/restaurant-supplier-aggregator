import { Controller } from "@hotwired/stimulus"

/**
 * Auto-refreshes the current page on an interval.
 * Properly cleans up when navigating away (unlike <meta http-equiv="refresh">
 * which persists across Turbo Drive navigations and yanks users back).
 *
 * Usage:
 *   <div data-controller="auto-refresh"
 *        data-auto-refresh-interval-value="10000">
 *   </div>
 */
export default class extends Controller {
  static values = {
    interval: { type: Number, default: 10000 }
  }

  connect() {
    this.timer = setInterval(() => {
      window.location.reload()
    }, this.intervalValue)
  }

  disconnect() {
    if (this.timer) {
      clearInterval(this.timer)
      this.timer = null
    }
  }
}
