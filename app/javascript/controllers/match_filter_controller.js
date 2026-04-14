import { Controller } from "@hotwired/stimulus"

// Filters product match rows on the aggregated list show page.
// KPI cards (Total / Matched / Unmatched) act as toggle buttons.
export default class extends Controller {
  static targets = ["card", "row", "categoryGroup"]

  connect() {
    this._currentFilter = "all"
  }

  setFilter(event) {
    const filter = event.currentTarget.dataset.filter
    this._currentFilter = filter
    this._applyFilter()
    this._updateCardStyles()
  }

  _applyFilter() {
    this.rowTargets.forEach(row => {
      const status = row.dataset.matchStatus
      const visible = this._currentFilter === "all" || this._currentFilter === status
      row.classList.toggle("hidden", !visible)
    })
    // Hide category groups that have no visible rows
    this.categoryGroupTargets.forEach(group => {
      const visibleRows = group.querySelectorAll("[data-match-filter-target='row']:not(.hidden)")
      group.classList.toggle("hidden", visibleRows.length === 0)
    })
  }

  _updateCardStyles() {
    this.cardTargets.forEach(card => {
      const isActive = card.dataset.filter === this._currentFilter
      card.classList.toggle("ring-brand-orange", isActive)
      card.classList.toggle("ring-transparent", !isActive)
    })
  }
}
