import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["quantityInput", "lineTotal", "runningTotal", "itemCount", "supplierCount", "submitButton"]

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
    this._fixedBar.style.cssText = "position:fixed;bottom:0;left:0;right:0;z-index:50;background:#f3f4f6;border-top:1px solid #d1d5db;padding:0.25rem 1rem 0.5rem;"
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
    this._fixedActionItemCount = this._fixedBar.querySelector("#action-bar-item-count")
    this._fixedActionRunningTotal = this._fixedBar.querySelector("#action-bar-running-total")

    // Remove Stimulus target attributes from clones (they're not in controller scope)
    this._fixedBar.querySelectorAll("[data-order-builder-target]").forEach(el => {
      el.removeAttribute("data-order-builder-target")
    })

    // Navy background — keep all white cards as-is (KPI cards + action row stay white)

    // Hide the original in-page bar
    cmdBar.style.visibility = "hidden"

    // Placeholder to keep layout spacing
    const barHeight = this._fixedBar.offsetHeight
    cmdBar.style.height = barHeight + "px"

    // Floating table header + auto-hide bottom bar when footer is visible
    const nav = document.querySelector("nav")
    const controllerEl = this.element

    if (thead && table) {
      this._floatingHeader = document.createElement("div")
      this._floatingHeader.style.cssText = "position:fixed;top:0;left:0;right:0;z-index:40;display:none;background:#11116b;border-bottom:1px solid #0d0d52;"
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

  updateTotals() {
    let total = 0
    let itemCount = 0
    const supplierIds = new Set()

    this.quantityInputTargets.forEach((input, index) => {
      const qty = parseInt(input.value) || 0
      const price = parseFloat(input.dataset.price) || 0
      const supplierId = input.dataset.supplierId
      const lineTotal = qty * price

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

    // Update Stimulus targets (original hidden bar)
    if (this.hasRunningTotalTarget) this.runningTotalTarget.textContent = `$${total.toFixed(2)}`
    if (this.hasItemCountTarget) this.itemCountTarget.textContent = itemCount
    if (this.hasSupplierCountTarget) this.supplierCountTarget.textContent = supplierIds.size

    // Update cloned fixed bar elements
    if (this._fixedItemCount) this._fixedItemCount.textContent = itemCount
    if (this._fixedRunningTotal) this._fixedRunningTotal.textContent = `$${total.toFixed(2)}`
    if (this._fixedSupplierCount) this._fixedSupplierCount.textContent = supplierIds.size
    if (this._fixedActionItemCount) this._fixedActionItemCount.textContent = itemCount
    if (this._fixedActionRunningTotal) this._fixedActionRunningTotal.textContent = `$${total.toFixed(2)}`

    // Enable/disable both submit buttons
    const buttons = [this.hasSubmitButtonTarget ? this.submitButtonTarget : null, this._fixedSubmitButton].filter(Boolean)
    buttons.forEach(btn => {
      if (itemCount > 0) {
        btn.disabled = false
        btn.classList.remove("bg-gray-300", "cursor-not-allowed")
        btn.classList.add("bg-brand-orange", "hover:bg-brand-orange-dark", "cursor-pointer")
      } else {
        btn.disabled = true
        btn.classList.add("bg-gray-300", "cursor-not-allowed")
        btn.classList.remove("bg-brand-orange", "hover:bg-brand-orange-dark", "cursor-pointer")
      }
    })
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
