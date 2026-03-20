import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["startDate", "endDate", "preset"]

  connect() {
    this._detectPreset()
  }

  apply(event) {
    const value = event.target.value
    if (!value) return

    const range = this._rangeFor(value)
    if (!range) return

    this.startDateTarget.value = this._formatDate(range.start)
    this.endDateTarget.value = this._formatDate(range.end)

    // Auto-submit the form
    this.element.requestSubmit()
  }

  // Check if current date values match any preset and select it
  _detectPreset() {
    const currentStart = this.startDateTarget.value
    const currentEnd = this.endDateTarget.value
    if (!currentStart || !currentEnd) return

    const presets = [
      "last_30", "last_60", "last_90",
      "this_month", "last_month",
      "this_quarter", "last_quarter",
      "this_year", "last_year"
    ]

    for (const key of presets) {
      const range = this._rangeFor(key)
      if (range &&
          this._formatDate(range.start) === currentStart &&
          this._formatDate(range.end) === currentEnd) {
        this.presetTarget.value = key
        return
      }
    }

    // No match — leave as "Custom"
    this.presetTarget.value = ""
  }

  _rangeFor(key) {
    const today = new Date()
    let start, end

    switch (key) {
      case "last_30":
        start = this._daysAgo(30)
        end = today
        break
      case "last_60":
        start = this._daysAgo(60)
        end = today
        break
      case "last_90":
        start = this._daysAgo(90)
        end = today
        break
      case "this_month":
        start = new Date(today.getFullYear(), today.getMonth(), 1)
        end = today
        break
      case "last_month":
        start = new Date(today.getFullYear(), today.getMonth() - 1, 1)
        end = new Date(today.getFullYear(), today.getMonth(), 0)
        break
      case "this_quarter":
        start = new Date(today.getFullYear(), Math.floor(today.getMonth() / 3) * 3, 1)
        end = today
        break
      case "last_quarter": {
        const qStart = Math.floor(today.getMonth() / 3) * 3
        start = new Date(today.getFullYear(), qStart - 3, 1)
        end = new Date(today.getFullYear(), qStart, 0)
        break
      }
      case "this_year":
        start = new Date(today.getFullYear(), 0, 1)
        end = today
        break
      case "last_year":
        start = new Date(today.getFullYear() - 1, 0, 1)
        end = new Date(today.getFullYear() - 1, 11, 31)
        break
      default:
        return null
    }

    return { start, end }
  }

  _daysAgo(n) {
    const d = new Date()
    d.setDate(d.getDate() - n)
    return d
  }

  _formatDate(date) {
    const y = date.getFullYear()
    const m = String(date.getMonth() + 1).padStart(2, "0")
    const d = String(date.getDate()).padStart(2, "0")
    return `${y}-${m}-${d}`
  }
}
