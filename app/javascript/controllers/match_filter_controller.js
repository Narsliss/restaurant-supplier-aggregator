import { Controller } from "@hotwired/stimulus"

// Filters product match rows on the aggregated list show page.
// KPI cards (Total / Matched / Unmatched) act as toggle buttons, and the
// search box narrows by product name. The two combine: a row must pass both.
export default class extends Controller {
  static targets = ["card", "row", "categoryGroup", "input", "clearButton", "emptyState", "resultCount"]

  connect() {
    this._currentFilter = "all"
    this._searchTokens = []
  }

  disconnect() {
    clearTimeout(this._searchTimeout)
  }

  setFilter(event) {
    const filter = event.currentTarget.dataset.filter
    this._currentFilter = filter
    this._applyFilter()
    this._updateCardStyles()
  }

  search() {
    clearTimeout(this._searchTimeout)
    this._searchTimeout = setTimeout(() => {
      const query = this.inputTarget.value.toLowerCase().trim()
      // Word-level matching: every typed word must appear somewhere in the
      // name, in any order — "chicken" finds "Blue Farms Chicken Pieces".
      this._searchTokens = query.split(/\s+/).filter(t => t.length > 0)
      if (this.hasClearButtonTarget) {
        this.clearButtonTarget.classList.toggle("hidden", this.inputTarget.value === "")
      }
      this._applyFilter()
    }, 150)
  }

  clearSearch() {
    this.inputTarget.value = ""
    this._searchTokens = []
    if (this.hasClearButtonTarget) this.clearButtonTarget.classList.add("hidden")
    this._applyFilter()
    this.inputTarget.focus()
  }

  _applyFilter() {
    let visibleCount = 0
    this.rowTargets.forEach(row => {
      const visible = this._matchesStatus(row) && this._matchesSearch(row)
      row.classList.toggle("hidden", !visible)
      if (visible) visibleCount++
    })
    // Hide category groups that have no visible rows; keep the visible ones'
    // header counts honest while a filter is narrowing them.
    this.categoryGroupTargets.forEach(group => {
      const visibleRows = group.querySelectorAll("[data-match-filter-target='row']:not(.hidden)")
      group.classList.toggle("hidden", visibleRows.length === 0)
      const count = group.querySelector("[data-category-count]")
      if (count) count.textContent = visibleRows.length
    })
    if (this.hasEmptyStateTarget) {
      this.emptyStateTarget.classList.toggle("hidden", visibleCount > 0)
    }
    // "14 of 172" beside the input while a search is narrowing the list —
    // instant feedback that the box is doing something.
    if (this.hasResultCountTarget) {
      const searching = this._searchTokens.length > 0
      this.resultCountTarget.classList.toggle("hidden", !searching)
      if (searching) {
        this.resultCountTarget.textContent = `${visibleCount} of ${this.rowTargets.length}`
      }
    }
  }

  _matchesStatus(row) {
    return this._currentFilter === "all" || this._currentFilter === row.dataset.matchStatus
  }

  _matchesSearch(row) {
    if (this._searchTokens.length === 0) return true
    // The name lives on the left cell (kept fresh by the rename turbo stream),
    // not on the card root.
    const name = row.querySelector("[data-search-name]")?.dataset.searchName || ""
    return this._searchTokens.every(token => name.includes(token))
  }

  _updateCardStyles() {
    this.cardTargets.forEach(card => {
      const isActive = card.dataset.filter === this._currentFilter
      card.classList.toggle("ring-brand-orange", isActive)
      card.classList.toggle("ring-transparent", !isActive)
    })
  }
}
