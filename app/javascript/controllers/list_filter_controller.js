import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "item", "clearButton"]

  clear() {
    this.inputTarget.value = ""
    this.filter()
    this.inputTarget.focus()
  }

  filter() {
    const query = this.inputTarget.value.toLowerCase().trim()
    if (this.hasClearButtonTarget) this.clearButtonTarget.classList.toggle("hidden", this.inputTarget.value === "")
    this.itemTargets.forEach(item => {
      const text = item.dataset.filterText || item.textContent.toLowerCase()
      item.style.display = text.includes(query) ? "" : "none"
    })
  }
}
