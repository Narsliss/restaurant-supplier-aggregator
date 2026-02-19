import { Controller } from "@hotwired/stimulus"

// Toggles visibility of an inline form and swaps button text.
//
// Usage:
//   <div data-controller="inline-form">
//     <button data-action="inline-form#toggle"
//             data-inline-form-show-text-value="+ New Comparison"
//             data-inline-form-hide-text-value="Cancel">
//       + New Comparison
//     </button>
//     <div data-inline-form-target="form" class="hidden">
//       ...form content...
//     </div>
//   </div>
export default class extends Controller {
  static targets = ["form", "button"]
  static values = {
    showText: { type: String, default: "+ New Comparison" },
    hideText: { type: String, default: "Cancel" }
  }

  toggle() {
    const isHidden = this.formTarget.classList.contains("hidden")

    if (isHidden) {
      this.formTarget.classList.remove("hidden")
      if (this.hasButtonTarget) {
        this.buttonTarget.textContent = this.hideTextValue
      }
    } else {
      this.formTarget.classList.add("hidden")
      if (this.hasButtonTarget) {
        this.buttonTarget.textContent = this.showTextValue
      }
    }
  }
}
