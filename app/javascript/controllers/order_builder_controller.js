import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["quantityInput", "lineTotal", "runningTotal", "itemCount", "supplierCount", "submitButton", "deliveryDate", "supplierCell"]

  connect() {
    this.updateTotals()
    this._setupFixedUI()
  }

  disconnect() {
    if (this._scrollHandler) window.removeEventListener("scroll", this._scrollHandler)
    if (this._fixedBar) this._fixedBar.remove()
    if (this._floatingHeader) this._floatingHeader.remove()
  }

  _setupFixedUI() {
    const cmdBar = document.getElementById("order-builder-command-bar")
    const thead = document.getElementById("order-builder-thead")
    const table = document.getElementById("order-builder-table")
    if (!cmdBar) return

    // Clone the command bar into a fixed div on document.body
    this._fixedBar = document.createElement("div")
    this._fixedBar.style.cssText = "position:fixed;bottom:0;left:0;right:0;z-index:50;background:#3A6147;border-top:1px solid #2D5A3D;padding:0.25rem 1rem 0.5rem;"
    this._fixedBar.innerHTML = `<div style="max-width:72rem;margin:0 auto;">${cmdBar.innerHTML}</div>`
    document.body.appendChild(this._fixedBar)

    // Wire up the cloned submit button to submit the real form
    const clonedSubmit = this._fixedBar.querySelector("button[type='submit']")
    if (clonedSubmit) {
      clonedSubmit.addEventListener("click", (e) => {
        e.preventDefault()
        const form = document.getElementById("order-form")
        if (form) form.requestSubmit()
      })
    }

    // Store refs to cloned KPI elements for updating
    this._fixedItemCount = this._fixedBar.querySelector("[data-order-builder-target='itemCount']")
    this._fixedRunningTotal = this._fixedBar.querySelector("[data-order-builder-target='runningTotal']")
    this._fixedSupplierCount = this._fixedBar.querySelector("[data-order-builder-target='supplierCount']")
    this._fixedSubmitButton = clonedSubmit
    this._fixedDeliveryDate = this._fixedBar.querySelector("input[name='delivery_date']")

    // Sync delivery date changes between original (hidden) and fixed bar clone
    if (this._fixedDeliveryDate && this.hasDeliveryDateTarget) {
      this._fixedDeliveryDate.addEventListener("change", () => {
        this.deliveryDateTarget.value = this._fixedDeliveryDate.value
        this._clearDateHighlight()
        this.updateTotals()
      })
      this.deliveryDateTarget.addEventListener("change", () => {
        this._fixedDeliveryDate.value = this.deliveryDateTarget.value
        this._clearDateHighlight()
        this.updateTotals()
      })
    }

    // Remove Stimulus target attributes from clones (they're not in controller scope)
    this._fixedBar.querySelectorAll("[data-order-builder-target]").forEach(el => {
      el.removeAttribute("data-order-builder-target")
    })

    // Navy background — keep all white cards as-is (KPI cards + action row stay white)

    // Hide the original in-page bar completely (no placeholder — bar is fixed at bottom)
    cmdBar.style.display = "none"

    // Floating table header + auto-hide bottom bar when footer is visible
    const nav = document.querySelector("nav")
    const controllerEl = this.element

    if (thead && table) {
      this._floatingHeader = document.createElement("div")
      this._floatingHeader.style.cssText = "position:fixed;top:0;left:0;right:0;z-index:40;display:none;background:#3A6147;border-bottom:1px solid #2D5A3D;"
      document.body.appendChild(this._floatingHeader)

      this._scrollHandler = () => {
        // Determine where the nav ends (0 if scrolled away)
        const navBottom = nav ? Math.max(0, nav.getBoundingClientRect().bottom) : 0
        const theadRect = thead.getBoundingClientRect()
        const tableRect = table.getBoundingClientRect()
        const fixedBarTop = this._fixedBar.getBoundingClientRect().top

        // Show floating header when real thead scrolls above the nav bottom
        if (theadRect.top < navBottom && tableRect.bottom > fixedBarTop) {
          const realCells = thead.querySelectorAll("th")

          let html = "<table style='border-collapse:collapse;'><thead><tr>"
          realCells.forEach((cell) => {
            const w = cell.getBoundingClientRect().width
            // Override gray classes with white text on navy background
            const cls = cell.className
              .replace(/bg-gray-\d+/g, "")
              .replace(/text-gray-\d+/g, "text-white")
              .replace(/border-b\s+border-gray-\d+/g, "")
            html += `<th style="width:${w}px;" class="${cls}">${cell.innerHTML}</th>`
          })
          html += "</tr></thead></table>"

          this._floatingHeader.style.top = navBottom + "px"
          this._floatingHeader.style.left = tableRect.left + "px"
          this._floatingHeader.style.right = (window.innerWidth - tableRect.right) + "px"
          this._floatingHeader.style.display = "block"
          this._floatingHeader.innerHTML = html
        } else {
          this._floatingHeader.style.display = "none"
        }

        // When footer is visible, push the bar up so it sits above the footer
        const containerBottom = controllerEl.getBoundingClientRect().bottom
        const barHeight = this._fixedBar.offsetHeight
        if (containerBottom < window.innerHeight) {
          // Content has ended — lock bar at the bottom of the content area
          const offset = window.innerHeight - containerBottom
          this._fixedBar.style.bottom = offset + "px"
        } else {
          this._fixedBar.style.bottom = "0"
        }
      }

      window.addEventListener("scroll", this._scrollHandler, { passive: true })
    }
  }

  // Set the value for ALL inputs sharing the same match ID (desktop + mobile)
  _setMatchQuantity(matchId, value) {
    this.quantityInputTargets.forEach(input => {
      if (input.dataset.matchId === matchId) {
        input.value = value
      }
    })
  }

  updateTotals() {
    let total = 0
    let itemCount = 0
    const supplierIds = new Set()
    const seenMatches = new Set()

    this.quantityInputTargets.forEach((input, index) => {
      const matchId = input.dataset.matchId
      const qty = parseInt(input.value) || 0
      const price = parseFloat(input.dataset.price) || 0
      const supplierId = input.dataset.supplierId
      const lineTotal = qty * price

      // Update the line total display for this row
      if (this.lineTotalTargets[index]) {
        this.lineTotalTargets[index].textContent = lineTotal > 0
          ? `$${lineTotal.toFixed(2)}`
          : "\u2014"
      }

      // Only count each match once for KPI totals (desktop + mobile are duplicates)
      if (matchId && !seenMatches.has(matchId)) {
        seenMatches.add(matchId)
        if (qty > 0) {
          total += lineTotal
          itemCount++
          if (supplierId) supplierIds.add(supplierId)
        }
      }
    })

    // Update Stimulus targets (original hidden bar)
    if (this.hasRunningTotalTarget) this.runningTotalTarget.textContent = `$${total.toFixed(2)}`
    if (this.hasItemCountTarget) this.itemCountTarget.textContent = itemCount
    if (this.hasSupplierCountTarget) this.supplierCountTarget.textContent = supplierIds.size

    // Update cloned fixed bar elements
    if (this._fixedItemCount) this._fixedItemCount.textContent = itemCount
    if (this._fixedRunningTotal) this._fixedRunningTotal.textContent = `$${total.toFixed(2)}`
    if (this._fixedSupplierCount) this._fixedSupplierCount.textContent = supplierIds.size

    // Check delivery date
    const hasDate = this._hasValidDeliveryDate()
    const canSubmit = itemCount > 0 && hasDate

    // Build tooltip explaining why submit is disabled
    let tooltip = ""
    if (!canSubmit) {
      const reasons = []
      if (itemCount === 0) reasons.push("select at least one item")
      if (!hasDate) reasons.push("choose a delivery date")
      tooltip = "To create orders, " + reasons.join(" and ")
    }

    // Enable/disable both submit buttons
    const buttons = [this.hasSubmitButtonTarget ? this.submitButtonTarget : null, this._fixedSubmitButton].filter(Boolean)
    buttons.forEach(btn => {
      if (canSubmit) {
        btn.disabled = false
        btn.classList.remove("bg-gray-300", "cursor-not-allowed")
        btn.classList.add("bg-brand-orange", "hover:bg-brand-orange-dark", "cursor-pointer")
        btn.title = ""
      } else {
        btn.disabled = true
        btn.classList.add("bg-gray-300", "cursor-not-allowed")
        btn.classList.remove("bg-brand-orange", "hover:bg-brand-orange-dark", "cursor-pointer")
        btn.title = tooltip
      }
    })

    // Highlight date field if items are selected but no date is set
    if (itemCount > 0 && !hasDate) {
      this._highlightDate()
    } else {
      this._clearDateHighlight()
    }
  }

  _hasValidDeliveryDate() {
    const input = this._fixedDeliveryDate || (this.hasDeliveryDateTarget ? this.deliveryDateTarget : null)
    if (!input || !input.value) return false
    const selected = new Date(input.value + "T00:00:00")
    const today = new Date()
    today.setHours(0, 0, 0, 0)
    return selected > today
  }

  _highlightDate() {
    const inputs = [this._fixedDeliveryDate].filter(Boolean)
    inputs.forEach(input => {
      input.classList.add("ring-2", "ring-brand-orange", "border-brand-orange")
    })
  }

  _clearDateHighlight() {
    const inputs = [this._fixedDeliveryDate].filter(Boolean)
    inputs.forEach(input => {
      input.classList.remove("ring-2", "ring-brand-orange", "border-brand-orange")
    })
  }

  selectSupplier(event) {
    const cell = event.currentTarget
    const matchId = cell.dataset.matchId
    const newPrice = parseFloat(cell.dataset.supplierPrice) || 0
    const newSupplierId = cell.dataset.supplierIdValue

    // Update all quantity inputs for this match (desktop + mobile) with new price/supplier
    this.quantityInputTargets.forEach(input => {
      if (input.dataset.matchId === matchId) {
        input.dataset.price = newPrice
        input.dataset.supplierId = newSupplierId
      }
    })

    // Update visual state: remove ring from all cells for this match, add to selected
    this.supplierCellTargets.forEach(c => {
      if (c.dataset.matchId === matchId) {
        c.classList.remove("ring-2", "ring-1", "ring-brand-green", "bg-green-50")
        c.classList.add("hover:bg-gray-100")
      }
    })
    // Highlight clicked cell (and its counterpart on mobile/desktop)
    this.supplierCellTargets.forEach(c => {
      if (c.dataset.matchId === matchId && c.dataset.supplierIdValue === newSupplierId) {
        c.classList.add("ring-2", "ring-brand-green", "bg-green-50")
        c.classList.remove("hover:bg-gray-100")
      }
    })

    // Update hidden override field so the form submission knows which supplier was picked
    let overridesDiv = document.getElementById("supplier-overrides")
    let existing = overridesDiv.querySelector(`input[name="supplier_overrides[${matchId}]"]`)
    if (existing) {
      existing.value = newSupplierId
    } else {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = `supplier_overrides[${matchId}]`
      input.value = newSupplierId
      overridesDiv.appendChild(input)
    }

    this.updateTotals()
  }

  increment(event) {
    const input = event.currentTarget.closest("[data-order-builder-row]").querySelector("[data-order-builder-target='quantityInput']")
    const newValue = (parseInt(input.value) || 0) + 1
    // Set all inputs for this match (desktop + mobile) to the new value
    this._setMatchQuantity(input.dataset.matchId, newValue)
    this.updateTotals()
  }

  decrement(event) {
    const input = event.currentTarget.closest("[data-order-builder-row]").querySelector("[data-order-builder-target='quantityInput']")
    const current = parseInt(input.value) || 0
    if (current > 0) {
      const newValue = current - 1
      // Set all inputs for this match (desktop + mobile) to the new value
      this._setMatchQuantity(input.dataset.matchId, newValue)
      this.updateTotals()
    }
  }
}
