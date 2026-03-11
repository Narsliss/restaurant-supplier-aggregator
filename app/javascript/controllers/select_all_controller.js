import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["toggle", "checkbox"]

  toggleAll() {
    const checked = this.toggleTarget.checked
    this.checkboxTargets.forEach(cb => cb.checked = checked)
  }
}
