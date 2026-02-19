import { Controller } from "@hotwired/stimulus"

// Searchable select that shows all items in a scrollable list.
// A text input at top filters items as the user types.
// On selection, sets a hidden field value and auto-submits the form.
// Closes the parent <details> when clicking outside.
export default class extends Controller {
  static targets = ["input", "hidden", "list"]

  connect() {
    // Bind filter directly to ensure it works
    this.inputTarget.addEventListener("input", () => this.filter())
    this.inputTarget.addEventListener("keyup", () => this.filter())

    // Close parent <details> when clicking outside
    this._clickOutside = (e) => {
      const details = this.element.closest("details")
      if (details && details.open && !details.contains(e.target)) {
        details.removeAttribute("open")
      }
    }
    document.addEventListener("click", this._clickOutside)
  }

  disconnect() {
    document.removeEventListener("click", this._clickOutside)
  }

  filter() {
    const query = this.inputTarget.value.toLowerCase()

    this.listTarget.querySelectorAll("li[data-value]").forEach((li) => {
      const text = li.textContent.toLowerCase()
      const visible = query === "" || text.includes(query)
      li.style.display = visible ? "" : "none"
    })
  }

  select(event) {
    const li = event.currentTarget
    const value = li.dataset.value
    const label = li.textContent.trim()

    this.hiddenTarget.value = value
    this.inputTarget.value = label

    // Auto-submit the parent form
    const form = this.element.closest("form")
    if (form) {
      form.requestSubmit()
    }
  }
}
