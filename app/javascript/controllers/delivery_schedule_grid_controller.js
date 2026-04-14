import { Controller } from "@hotwired/stimulus"

// Manages the delivery schedule grid on the organization settings page.
// Handles day pill toggles, cutoff day/time changes, and auto-saves via AJAX.
export default class extends Controller {
  static values = { url: String }

  connect() {
    this.element.querySelectorAll("[data-day-pill]").forEach(pill => {
      pill.addEventListener("click", this.toggleDay.bind(this))
    })

    this.element.querySelectorAll("[data-cutoff-field]").forEach(input => {
      input.addEventListener("change", this.updateCutoff.bind(this))
    })
  }

  async toggleDay(event) {
    const pill = event.currentTarget
    const supplierId = pill.dataset.supplierId
    const dayOfWeek = parseInt(pill.dataset.dayOfWeek)
    const isActive = pill.dataset.active === "true"
    const newState = !isActive

    // Optimistic UI update
    pill.dataset.active = newState.toString()
    this._stylePill(pill, newState)

    // Show/hide cutoff row
    const cutoffRow = this.element.querySelector(
      `[data-cutoff-row][data-supplier-id="${supplierId}"][data-day-of-week="${dayOfWeek}"]`
    )
    if (cutoffRow) {
      cutoffRow.classList.toggle("hidden", !newState)
    }

    await this._save(supplierId, dayOfWeek, newState)
  }

  async updateCutoff(event) {
    const input = event.currentTarget
    const supplierId = input.dataset.supplierId
    const dayOfWeek = parseInt(input.dataset.dayOfWeek)

    const row = this.element.querySelector(
      `[data-cutoff-row][data-supplier-id="${supplierId}"][data-day-of-week="${dayOfWeek}"]`
    )
    if (!row) return

    const cutoffDay = row.querySelector("[data-cutoff-day]")?.value
    const cutoffTime = row.querySelector("[data-cutoff-time]")?.value

    await this._save(supplierId, dayOfWeek, true, cutoffDay, cutoffTime)
  }

  async _save(supplierId, dayOfWeek, enabled, cutoffDay, cutoffTime) {
    const pill = this.element.querySelector(
      `[data-day-pill][data-supplier-id="${supplierId}"][data-day-of-week="${dayOfWeek}"]`
    )

    try {
      const body = {
        supplier_id: supplierId,
        day_of_week: dayOfWeek,
        enabled: enabled
      }
      if (cutoffDay !== undefined) body.cutoff_day = cutoffDay
      if (cutoffTime !== undefined) body.cutoff_time = cutoffTime

      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrfToken,
          "Accept": "application/json"
        },
        body: JSON.stringify(body)
      })

      if (response.ok) {
        const data = await response.json()
        this._flashSuccess(pill)

        // Update the formatted schedule text if present
        if (data.schedule) {
          const formatted = this.element.querySelector(
            `[data-schedule-text][data-supplier-id="${supplierId}"][data-day-of-week="${dayOfWeek}"]`
          )
          if (formatted) formatted.textContent = data.schedule.formatted
        }
      } else {
        this._flashError(pill)
        // Revert optimistic update on failure
        if (pill) {
          const reverted = !(pill.dataset.active === "true")
          pill.dataset.active = reverted.toString()
          this._stylePill(pill, reverted)
        }
      }
    } catch (error) {
      console.error("Failed to save delivery schedule:", error)
      this._flashError(pill)
    }
  }

  _stylePill(pill, active) {
    if (active) {
      pill.classList.remove("bg-gray-100", "text-gray-400", "hover:bg-gray-200")
      pill.classList.add("bg-brand-green", "text-white", "hover:bg-brand-green-dark")
    } else {
      pill.classList.remove("bg-brand-green", "text-white", "hover:bg-brand-green-dark")
      pill.classList.add("bg-gray-100", "text-gray-400", "hover:bg-gray-200")
    }
  }

  _flashSuccess(el) {
    if (!el) return
    el.classList.add("ring-2", "ring-green-400")
    setTimeout(() => el.classList.remove("ring-2", "ring-green-400"), 1000)
  }

  _flashError(el) {
    if (!el) return
    el.classList.add("ring-2", "ring-red-400")
    setTimeout(() => el.classList.remove("ring-2", "ring-red-400"), 2000)
  }

  get _csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
