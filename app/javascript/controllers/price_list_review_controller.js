import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["selectAll", "productCheckbox", "importButton", "selectedCount"]

  connect() {
    this.updateCount()
  }

  toggleAll() {
    const checked = this.selectAllTarget.checked
    this.productCheckboxTargets.forEach(cb => cb.checked = checked)
    this.updateCount()
  }

  updateCount() {
    const total = this.productCheckboxTargets.length
    const selected = this.productCheckboxTargets.filter(cb => cb.checked).length
    this.selectedCountTarget.textContent = selected
    this.selectAllTarget.checked = selected === total
    this.selectAllTarget.indeterminate = selected > 0 && selected < total
  }
}
