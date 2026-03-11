import { Controller } from "@hotwired/stimulus"

// AJAX-powered searchable select for product assignment.
// Fetches matching items from server on demand instead of pre-rendering
// thousands of <li> elements into the DOM.
//
// Uses a single shared document-level click handler (via class method)
// instead of one per instance, to avoid hundreds of duplicate handlers.
export default class extends Controller {
  static targets = ["input", "hidden", "list"]
  static values = {
    url: String,       // search endpoint URL
    supplierId: Number // which supplier to search within
  }

  // Shared click-outside handler — registered once for ALL instances
  static _instances = new Set()
  static _globalHandlerBound = false

  static _handleClickOutside(e) {
    if (e._searchableSelectHandled) return

    for (const instance of this._instances) {
      const details = instance.element.closest("details")
      if (details && details.open && !details.contains(e.target)) {
        details.removeAttribute("open")
      }
    }
  }

  connect() {
    this.constructor._instances.add(this)
    this.timeout = null
    this.loaded = false

    if (!this.constructor._globalHandlerBound) {
      this.constructor._globalHandlerBound = true
      document.addEventListener("click", (e) => this.constructor._handleClickOutside(e))
    }

    // Listen for <details> open to trigger initial load
    const details = this.element.closest("details")
    if (details) {
      details.addEventListener("toggle", () => {
        if (details.open && !this.loaded) {
          this.loaded = true
          this.performSearch("")
        }
        if (details.open) {
          setTimeout(() => this.inputTarget.focus(), 50)
        }
      })
    }
  }

  disconnect() {
    this.constructor._instances.delete(this)
    if (this.timeout) clearTimeout(this.timeout)
  }

  filter() {
    const query = this.inputTarget.value.trim()

    if (this.timeout) clearTimeout(this.timeout)

    this.timeout = setTimeout(() => {
      this.performSearch(query)
    }, 250)
  }

  async performSearch(query) {
    if (!this.hasUrlValue) return

    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("supplier_id", this.supplierIdValue)
    if (query) url.searchParams.set("q", query)

    try {
      const response = await fetch(url, {
        headers: {
          "Accept": "application/json",
          "X-Requested-With": "XMLHttpRequest"
        }
      })

      if (!response.ok) throw new Error(`HTTP ${response.status}`)

      const items = await response.json()
      this.renderResults(items)
    } catch (error) {
      console.error("Searchable select error:", error)
      this.renderError()
    }
  }

  renderResults(items) {
    // Clear dynamic items but keep "No Match" option
    this.listTarget.querySelectorAll("li:not([data-no-filter])").forEach(li => li.remove())

    if (items.length === 0) {
      const li = document.createElement("li")
      li.className = "px-3 py-2 text-gray-400 text-center italic"
      li.textContent = "No items found"
      this.listTarget.appendChild(li)
      return
    }

    const selectedId = this.hiddenTarget.value

    items.forEach(item => {
      const li = document.createElement("li")
      li.dataset.value = item.id
      li.dataset.action = "click->searchable-select#select"
      li.className = `cursor-pointer px-3 py-1.5 hover:bg-brand-orange hover:text-white ${String(item.id) === String(selectedId) ? 'bg-brand-orange/10 font-medium' : ''}`

      let text = `${item.name} — ${item.price}`
      if (item.pack_size) text += ` (${item.pack_size})`

      if (item.source === "catalog") {
        const span = document.createElement("span")
        span.className = "text-xs text-blue-500 ml-1"
        span.textContent = "(catalog)"
        li.textContent = text
        li.appendChild(span)
      } else {
        li.textContent = text
      }

      this.listTarget.appendChild(li)
    })
  }

  renderError() {
    this.listTarget.querySelectorAll("li:not([data-no-filter])").forEach(li => li.remove())
    const li = document.createElement("li")
    li.className = "px-3 py-2 text-red-500 text-center"
    li.textContent = "Search error. Try again."
    this.listTarget.appendChild(li)
  }

  select(event) {
    event.stopPropagation()
    event._searchableSelectHandled = true

    const li = event.currentTarget
    const value = li.dataset.value
    const label = li.textContent.trim()

    this.hiddenTarget.value = value
    this.inputTarget.value = label

    const details = this.element.closest("details")
    if (details) details.removeAttribute("open")

    const form = this.element.closest("form")
    if (form) {
      form.requestSubmit()
    }
  }
}
