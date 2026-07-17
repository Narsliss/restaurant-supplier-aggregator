import { Controller } from "@hotwired/stimulus"
import { openCalendar, dateLabel, confettiBurst } from "controllers/mobile_calendar"

// Mobile cart/review page (Comp A). Delivery dates use the comp's bottom-sheet
// calendar and PATCH the order (same JSON endpoint desktop uses). Line
// quantities edit through the existing nested order_items endpoints. Place
// submits the existing submit_batch form with a confetti send-off.
export default class extends Controller {
  static targets = ["dateButton", "dateText", "placeButton"]

  headers() {
    return {
      "Content-Type": "application/json",
      "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
      "Accept": "application/json"
    }
  }

  // ---- Delivery date (bottom-sheet calendar) ----

  openDatePicker(event) {
    const btn = event.currentTarget
    openCalendar(btn.dataset.date, async iso => {
      await fetch(`/orders/${btn.dataset.orderId}`, {
        method: "PATCH",
        headers: this.headers(),
        body: JSON.stringify({ order: { delivery_date: iso } })
      })
      btn.dataset.date = iso
      btn.classList.remove("ring-2", "ring-inset", "ring-amber-400")
      btn.querySelector("[data-mobile-review-target='dateText']").textContent = dateLabel(iso)
      this.updatePlaceState()
    })
  }

  // ---- Line quantity steppers (existing order_items endpoints) ----

  incrementItem(event) { this.changeItem(event, +1) }
  decrementItem(event) { this.changeItem(event, -1) }

  async changeItem(event, delta) {
    const btn = event.currentTarget
    const { orderId, itemId } = btn.dataset
    const newQty = parseInt(btn.dataset.quantity, 10) + delta
    btn.disabled = true

    if (newQty <= 0) {
      await fetch(`/orders/${orderId}/order_items/${itemId}`, { method: "DELETE", headers: this.headers() })
    } else {
      await fetch(`/orders/${orderId}/order_items/${itemId}`, {
        method: "PATCH",
        headers: this.headers(),
        body: JSON.stringify({ quantity: newQty })
      })
    }
    // Totals, minimums, and savings are server-computed — refresh the page state
    window.Turbo ? window.Turbo.visit(window.location.href, { action: "replace" }) : window.location.reload()
  }

  updatePlaceState() {
    if (!this.hasPlaceButtonTarget) return
    const missing = this.dateButtonTargets.some(btn => !btn.dataset.date)
    const blockedByMinimum = this.placeButtonTarget.dataset.minimumsMet !== "true"
    this.placeButtonTarget.disabled = missing || blockedByMinimum
  }

  place(event) {
    confettiBurst(event.currentTarget, 24)
  }
}
