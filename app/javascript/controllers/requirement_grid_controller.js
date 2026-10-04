import { Controller } from "@hotwired/stimulus"

// Handles the supplier requirements grid — saves each restaurant's minimum on
// change via AJAX. (The EnPlace-wide default is read-only here since Oct 2026:
// it is shared by every restaurant, so editing it no longer locks or clears
// anyone's per-restaurant values.)
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
        // Flash green to confirm save
        input.classList.add("border-green-400", "bg-green-50")
        setTimeout(() => {
          input.classList.remove("border-green-400", "bg-green-50")
        }, 1000)

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

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
