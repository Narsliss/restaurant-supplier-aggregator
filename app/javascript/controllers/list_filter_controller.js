import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "item"]

  filter() {
    const query = this.inputTarget.value.toLowerCase().trim()
    this.itemTargets.forEach(item => {
      const text = item.dataset.filterText || item.textContent.toLowerCase()
      item.style.display = text.includes(query) ? "" : "none"
    })
  }
}
