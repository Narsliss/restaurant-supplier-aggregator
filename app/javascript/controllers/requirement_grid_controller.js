import { Controller } from "@hotwired/stimulus"

// Handles the supplier requirements grid — saves each input on change via AJAX.
// When a default (global) value is set, location cells for that row lock automatically.
export default class extends Controller {
  static values = { url: String }

  connect() {
    // Bind change events on all requirement inputs
    this.element.querySelectorAll("input[data-requirement]").forEach(input => {
      input.addEventListener("change", this.save.bind(this))
    })
  }

  async save(event) {
    const input = event.target
    const supplierId = input.dataset.supplierId
    const reqType = input.dataset.requirementType
    const locationId = input.dataset.locationId || ""
    const value = input.value || "0"

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken,
          "Accept": "application/json"
        },
        body: JSON.stringify({
          supplier_id: supplierId,
          requirement_type: reqType,
          location_id: locationId,
          value: value
        })
      })

      if (response.ok) {
        const data = await response.json()

        // Flash green to confirm save
        input.classList.add("border-green-400", "bg-green-50")
        setTimeout(() => {
          input.classList.remove("border-green-400", "bg-green-50")
        }, 1000)

        // If a global default was set or removed, update location cells
        if (data.global !== undefined) {
          this.updateLocationCells(supplierId, reqType, data)
        }
      } else {
        input.classList.add("border-red-400", "bg-red-50")
        setTimeout(() => {
          input.classList.remove("border-red-400", "bg-red-50")
        }, 2000)
      }
    } catch (error) {
      console.error("Failed to save requirement:", error)
      input.classList.add("border-red-400", "bg-red-50")
      setTimeout(() => {
        input.classList.remove("border-red-400", "bg-red-50")
      }, 2000)
    }
  }

  updateLocationCells(supplierId, reqType, data) {
    const rowKey = `${supplierId}-${reqType}`
    const locationCells = this.element.querySelectorAll(
      `[data-location-cell="${rowKey}"]`
    )
    const defaultInput = this.element.querySelector(
      `input[data-supplier-id="${supplierId}"][data-requirement-type="${reqType}"]:not([data-location-id])`
    )
    const defaultValue = defaultInput?.value

    locationCells.forEach(cell => {
      if (defaultValue && parseFloat(defaultValue) > 0) {
        // Lock: show locked display
        const formattedValue = reqType === "order_minimum"
          ? `$${parseFloat(defaultValue).toFixed(2)}`
          : parseInt(defaultValue)
        cell.innerHTML = `
          <span class="inline-flex items-center gap-1 text-xs text-gray-400" title="Locked — using default (${formattedValue})">
            <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"/></svg>
            ${formattedValue}
          </span>`
      } else {
        // Unlock: restore input
        const locId = cell.dataset.locId
        const step = reqType === "order_minimum" ? "0.01" : "1"
        const width = reqType === "order_minimum" ? "w-20" : "w-16"
        cell.innerHTML = `
          <input type="number" data-requirement data-supplier-id="${supplierId}"
                 data-requirement-type="${reqType}" data-location-id="${locId}"
                 placeholder="—" min="0" step="${step}"
                 class="${width} rounded-md border-gray-300 text-sm px-2 py-1 text-center">`

        // Rebind change event on new input
        const newInput = cell.querySelector("input")
        newInput.addEventListener("change", this.save.bind(this))
      }
    })
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
