import { Controller } from "@hotwired/stimulus"

// Click-to-edit inline text field.
//
// Usage:
//   <div data-controller="inline-edit"
//        data-inline-edit-url-value="/menu-planner/1"
//        data-inline-edit-field-value="title">
//     <span data-inline-edit-target="display" data-action="click->inline-edit#edit">
//       Wine Dinner - 50 covers
//     </span>
//     <input data-inline-edit-target="input" class="hidden"
//            data-action="blur->inline-edit#save keydown->inline-edit#keydown">
//   </div>
export default class extends Controller {
  static targets = ["display", "input", "icon"]
  static values = {
    url: String,
    field: String,
    param: String   // optional wrapper key (e.g. "event_plan" → { event_plan: { field: value } })
  }

  edit() {
    const currentText = this.displayTarget.textContent.trim()
    this.inputTarget.value = currentText
    this.displayTarget.classList.add("hidden")
    if (this.hasIconTarget) this.iconTarget.classList.add("hidden")
    this.inputTarget.classList.remove("hidden")
    this.inputTarget.focus()
    this.inputTarget.select()
  }

  _showDisplay() {
    this.inputTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
    if (this.hasIconTarget) this.iconTarget.classList.remove("hidden")
  }

  save() {
    const newValue = this.inputTarget.value.trim()
    const oldValue = this.displayTarget.textContent.trim()

    this._showDisplay()

    if (newValue === "" || newValue === oldValue) return

    this.displayTarget.textContent = newValue

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(this.urlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "Accept": "application/json"
      },
      body: JSON.stringify(this.hasParamValue
        ? { [this.paramValue]: { [this.fieldValue]: newValue } }
        : { [this.fieldValue]: newValue }
      )
    }).then(response => {
      if (!response.ok) {
        // Revert on failure
        this.displayTarget.textContent = oldValue
      }
    }).catch(() => {
      this.displayTarget.textContent = oldValue
    })
  }

  keydown(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.save()
    } else if (event.key === "Escape") {
      this._showDisplay()
    }
  }
}
