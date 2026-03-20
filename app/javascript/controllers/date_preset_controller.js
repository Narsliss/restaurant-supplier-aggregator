import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["startDate", "endDate", "preset"]

  apply(event) {
    const value = event.target.value
    if (!value) return

    const today = new Date()
    let start, end

    switch (value) {
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
        return
    }

    this.startDateTarget.value = this._formatDate(start)
    this.endDateTarget.value = this._formatDate(end)

    // Auto-submit the form
    this.element.requestSubmit()
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
