import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["quantityInput", "lineTotal", "runningTotal", "itemCount", "supplierCount", "submitButton"]

  connect() {
    this.updateTotals()
  }

  updateTotals() {
    let total = 0
    let itemCount = 0
    const supplierIds = new Set()

    this.quantityInputTargets.forEach((input, index) => {
      const qty = parseInt(input.value) || 0
      const price = parseFloat(input.dataset.price) || 0
      const supplierId = input.dataset.supplierId
      const lineTotal = qty * price

      // Update per-row line total
      if (this.lineTotalTargets[index]) {
        this.lineTotalTargets[index].textContent = lineTotal > 0
          ? `$${lineTotal.toFixed(2)}`
          : "\u2014"
      }

      if (qty > 0) {
        total += lineTotal
        itemCount++
        if (supplierId) supplierIds.add(supplierId)
      }
    })

    // Update summary displays
    if (this.hasRunningTotalTarget) {
      this.runningTotalTarget.textContent = `$${total.toFixed(2)}`
    }
    if (this.hasItemCountTarget) {
      this.itemCountTarget.textContent = itemCount
    }
    if (this.hasSupplierCountTarget) {
      this.supplierCountTarget.textContent = supplierIds.size
    }

    // Enable/disable submit button
    if (this.hasSubmitButtonTarget) {
      if (itemCount > 0) {
        this.submitButtonTarget.disabled = false
        this.submitButtonTarget.classList.remove("bg-gray-300", "cursor-not-allowed")
        this.submitButtonTarget.classList.add("bg-brand-orange", "hover:bg-brand-orange-dark", "cursor-pointer")
      } else {
        this.submitButtonTarget.disabled = true
        this.submitButtonTarget.classList.add("bg-gray-300", "cursor-not-allowed")
        this.submitButtonTarget.classList.remove("bg-brand-orange", "hover:bg-brand-orange-dark", "cursor-pointer")
      }
    }
  }

  increment(event) {
    const input = event.currentTarget.closest("[data-order-builder-row]").querySelector("[data-order-builder-target='quantityInput']")
    input.value = (parseInt(input.value) || 0) + 1
    this.updateTotals()
  }

  decrement(event) {
    const input = event.currentTarget.closest("[data-order-builder-row]").querySelector("[data-order-builder-target='quantityInput']")
    const current = parseInt(input.value) || 0
    if (current > 0) {
      input.value = current - 1
      this.updateTotals()
    }
  }
}
