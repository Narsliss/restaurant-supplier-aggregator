import { Controller } from "@hotwired/stimulus"

// Searchable select that shows all items in a scrollable list.
// A text input at top filters items as the user types.
// On selection, sets a hidden field value and auto-submits the form.
// Closes the parent <details> when clicking outside.
//
// Uses a single shared document-level click handler (via class method)
// instead of one per instance, to avoid hundreds of duplicate handlers.
export default class extends Controller {
  static targets = ["input", "hidden", "list"]

  // Shared click-outside handler — registered once for ALL instances
  static _instances = new Set()
  static _globalHandlerBound = false

  static _handleClickOutside(e) {
    // Skip if this click already triggered a form submission
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

    if (!this.constructor._globalHandlerBound) {
      this.constructor._globalHandlerBound = true
      document.addEventListener("click", (e) => this.constructor._handleClickOutside(e))
    }
  }

  disconnect() {
    this.constructor._instances.delete(this)
  }

  filter() {
    const query = this.inputTarget.value.toLowerCase()

    this.listTarget.querySelectorAll("li[data-value]").forEach((li) => {
      // "No Match" option stays visible regardless of search query
      if (li.dataset.noFilter === "true") return

      const text = li.textContent.toLowerCase()
      const visible = query === "" || text.includes(query)
      li.style.display = visible ? "" : "none"
    })
  }

  select(event) {
    // Stop propagation so _clickOutside doesn't fire and interfere
    event.stopPropagation()
    // Mark the event so the global handler skips it too (belt-and-suspenders)
    event._searchableSelectHandled = true

    const li = event.currentTarget
    const value = li.dataset.value
    const label = li.textContent.trim()

    this.hiddenTarget.value = value
    this.inputTarget.value = label

    // Close the dropdown immediately
    const details = this.element.closest("details")
    if (details) details.removeAttribute("open")

    // Auto-submit the parent form
    const form = this.element.closest("form")
    if (form) {
      form.requestSubmit()
    }
  }
}
