import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["customFields"]

  toggle(event) {
    const isCustom = event.target.value === "custom"
    this.customFieldsTarget.classList.toggle("hidden", !isCustom)
  }
}
