import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["quantityInput", "lineTotal", "runningTotal", "itemCount", "supplierCount", "submitButton", "deliveryDate", "supplierCell", "searchInput", "categorySection", "categoryContent", "chevron", "mobileSupplierDetail"]
  static values = { supplierMinimums: Object }

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

    // Wire up the cloned submit buttons to submit the real form
    this._fixedBar.querySelectorAll("button[type='submit']").forEach(btn => {
      btn.addEventListener("click", (e) => {
        e.preventDefault()
        const form = document.getElementById("order-form")
        if (form) form.requestSubmit()
      })
    })

    // Store refs to cloned KPI elements for updating (querySelectorAll for mobile+desktop duplicates)
    this._fixedItemCounts = this._fixedBar.querySelectorAll("[data-order-builder-target='itemCount']")
    this._fixedRunningTotals = this._fixedBar.querySelectorAll("[data-order-builder-target='runningTotal']")
    this._fixedSupplierCounts = this._fixedBar.querySelectorAll("[data-order-builder-target='supplierCount']")
    this._fixedSubmitButtons = this._fixedBar.querySelectorAll("button[type='submit']")
    this._fixedDeliveryDates = this._fixedBar.querySelectorAll("input[name='delivery_date']")

    // Store refs to supplier breakdown elements in the clone
    this._fixedSupplierCards = {}
    this._fixedSupplierSubtotals = {}
    this._fixedSupplierProgressBars = {}
    this._fixedSupplierMinLabels = {}
    this._fixedBar.querySelectorAll("[data-supplier-breakdown-id]").forEach(el => {
      const id = el.dataset.supplierBreakdownId
      if (!this._fixedSupplierCards[id]) this._fixedSupplierCards[id] = []
      this._fixedSupplierCards[id].push(el)
    })
    this._fixedBar.querySelectorAll("[data-supplier-subtotal]").forEach(el => {
      const id = el.dataset.supplierSubtotal
      if (!this._fixedSupplierSubtotals[id]) this._fixedSupplierSubtotals[id] = []
      this._fixedSupplierSubtotals[id].push(el)
    })
    this._fixedBar.querySelectorAll("[data-supplier-progress-bar]").forEach(el => {
      const id = el.dataset.supplierProgressBar
      if (!this._fixedSupplierProgressBars[id]) this._fixedSupplierProgressBars[id] = []
      this._fixedSupplierProgressBars[id].push(el)
    })
    this._fixedBar.querySelectorAll("[data-supplier-minimum-label]").forEach(el => {
      const id = el.dataset.supplierMinimumLabel
      if (!this._fixedSupplierMinLabels[id]) this._fixedSupplierMinLabels[id] = []
      this._fixedSupplierMinLabels[id].push(el)
    })

    // Store ref to mobile supplier detail panel in the clone
    this._fixedMobileSupplierDetail = this._fixedBar.querySelector("[data-order-builder-target='mobileSupplierDetail']")

    // Wire up the mobile supplier toggle in the cloned bar
    this._fixedBar.querySelectorAll("[data-action*='toggleMobileSupplierDetail']").forEach(el => {
      el.addEventListener("click", () => this.toggleMobileSupplierDetail())
    })

    // Sync delivery date changes between all cloned date inputs and original (hidden) targets
    this._fixedDeliveryDates.forEach(dateInput => {
      dateInput.addEventListener("change", () => {
        // Sync to all other cloned date inputs and original targets
        const val = dateInput.value
        this._fixedDeliveryDates.forEach(d => { if (d !== dateInput) d.value = val })
        this.deliveryDateTargets.forEach(d => d.value = val)
        this._clearDateHighlight()
        this.updateTotals()
      })
    })
    this.deliveryDateTargets.forEach(dateTarget => {
      dateTarget.addEventListener("change", () => {
        this._fixedDeliveryDates.forEach(d => d.value = dateTarget.value)
        this._clearDateHighlight()
        this.updateTotals()
      })
    })

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
    const supplierTotals = {}
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
          if (supplierId) {
            supplierIds.add(supplierId)
            supplierTotals[supplierId] = (supplierTotals[supplierId] || 0) + lineTotal
          }
        }
      }
    })

    // Update Stimulus targets (original hidden bar)
    if (this.hasRunningTotalTarget) this.runningTotalTarget.textContent = `$${total.toFixed(2)}`
    if (this.hasItemCountTarget) this.itemCountTarget.textContent = itemCount
    if (this.hasSupplierCountTarget) this.supplierCountTarget.textContent = supplierIds.size

    // Update cloned fixed bar elements (multiple for mobile+desktop)
    if (this._fixedItemCounts) this._fixedItemCounts.forEach(el => el.textContent = itemCount)
    if (this._fixedRunningTotals) this._fixedRunningTotals.forEach(el => el.textContent = `$${total.toFixed(2)}`)
    if (this._fixedSupplierCounts) this._fixedSupplierCounts.forEach(el => el.textContent = supplierIds.size)

    // Update per-supplier breakdown (mini-cards + progress bars)
    this._updateSupplierBreakdown(supplierTotals)

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

    // Enable/disable all submit buttons (original targets + cloned mobile/desktop)
    const buttons = [
      ...(this.hasSubmitButtonTarget ? this.submitButtonTargets : []),
      ...(this._fixedSubmitButtons || [])
    ]
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
    const allDates = [...(this._fixedDeliveryDates || []), ...(this.hasDeliveryDateTarget ? this.deliveryDateTargets : [])]
    const input = allDates.find(d => d.value)
    if (!input) return false
    const selected = new Date(input.value + "T00:00:00")
    const today = new Date()
    today.setHours(0, 0, 0, 0)
    return selected > today
  }

  _highlightDate() {
    const inputs = [...(this._fixedDeliveryDates || [])]
    inputs.forEach(input => {
      input.classList.add("ring-2", "ring-brand-orange", "border-brand-orange")
    })
  }

  _clearDateHighlight() {
    const inputs = [...(this._fixedDeliveryDates || [])]
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

  // === Per-supplier breakdown (progress bars + subtotals) ===
  _updateSupplierBreakdown(supplierTotals) {
    const minimums = this.supplierMinimumsValue || {}

    for (const [supplierId, config] of Object.entries(minimums)) {
      const subtotal = supplierTotals[supplierId] || 0
      const minimum = config.minimum
      const formattedSubtotal = `$${subtotal.toFixed(0)}`

      // Show/hide supplier card based on whether it has items
      const cardEls = [
        ...this.element.querySelectorAll(`[data-supplier-breakdown-id="${supplierId}"]`),
        ...(this._fixedSupplierCards?.[supplierId] || [])
      ]
      cardEls.forEach(el => {
        if (subtotal > 0) {
          el.classList.remove("hidden")
        } else {
          el.classList.add("hidden")
        }
      })

      // Update subtotal text in both original and cloned elements
      const subtotalEls = [
        ...this.element.querySelectorAll(`[data-supplier-subtotal="${supplierId}"]`),
        ...(this._fixedSupplierSubtotals?.[supplierId] || [])
      ]
      subtotalEls.forEach(el => el.textContent = formattedSubtotal)

      // Update progress bar and colors
      if (minimum && minimum > 0) {
        const percent = Math.min(100, (subtotal / minimum) * 100)
        const met = subtotal >= minimum

        const progressEls = [
          ...this.element.querySelectorAll(`[data-supplier-progress-bar="${supplierId}"]`),
          ...(this._fixedSupplierProgressBars?.[supplierId] || [])
        ]
        progressEls.forEach(bar => {
          bar.style.width = `${percent}%`
          bar.classList.remove("bg-brand-green", "bg-brand-orange", "bg-gray-300")
          if (subtotal === 0) {
            bar.classList.add("bg-gray-300")
          } else if (met) {
            bar.classList.add("bg-brand-green")
          } else {
            bar.classList.add("bg-brand-orange")
          }
        })

        // Update the minimum label: checkmark when met, fraction when not
        const labelEls = [
          ...this.element.querySelectorAll(`[data-supplier-minimum-label="${supplierId}"]`),
          ...(this._fixedSupplierMinLabels?.[supplierId] || [])
        ]
        labelEls.forEach(el => {
          if (met) {
            el.innerHTML = `<span class="text-brand-green font-medium">&#10003;</span>`
          } else {
            el.textContent = `/ $${minimum.toFixed(0)}`
          }
        })
      }
    }
  }

  toggleMobileSupplierDetail() {
    // Toggle in the cloned fixed bar
    if (this._fixedMobileSupplierDetail) {
      this._fixedMobileSupplierDetail.classList.toggle("hidden")
    }
    // Toggle in the original (hidden) bar too for consistency
    if (this.hasMobileSupplierDetailTarget) {
      this.mobileSupplierDetailTarget.classList.toggle("hidden")
    }
  }

  // === Feature 1: Search/Filter ===
  filterProducts() {
    const query = this.hasSearchInputTarget ? this.searchInputTarget.value.toLowerCase().trim() : ""

    this.element.querySelectorAll("[data-order-builder-row]").forEach(row => {
      const name = row.dataset.productName || ""
      row.style.display = (query === "" || name.includes(query)) ? "" : "none"
    })

    // Hide empty category sections
    if (this.hasCategorySectionTarget) {
      this.categorySectionTargets.forEach(section => {
        const visibleRows = section.querySelectorAll("[data-order-builder-row]:not([style*='display: none'])")
        section.style.display = visibleRows.length === 0 ? "none" : ""
      })
    }
  }

  // === Feature 3: Favorite Toggle ===
  async toggleFavorite(event) {
    event.preventDefault()
    event.stopPropagation()

    const button = event.currentTarget
    const spId = button.dataset.supplierProductId
    if (!spId) return

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    try {
      const response = await fetch("/favorite_products/toggle", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          "Accept": "application/json"
        },
        body: JSON.stringify({ supplier_product_id: spId })
      })

      if (!response.ok) return

      const data = await response.json()
      const favorited = data.favorited

      // Update ALL star buttons for this supplier product (desktop + mobile)
      document.querySelectorAll(`button[data-supplier-product-id="${spId}"]`).forEach(btn => {
        btn.dataset.favorited = favorited ? "true" : "false"
        if (favorited) {
          btn.innerHTML = `<svg class="w-4 h-4 text-amber-400" fill="currentColor" viewBox="0 0 20 20">
            <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.07 3.292a1 1 0 00.95.69h3.462c.969 0 1.371 1.24.588 1.81l-2.8 2.034a1 1 0 00-.364 1.118l1.07 3.292c.3.921-.755 1.688-1.54 1.118l-2.8-2.034a1 1 0 00-1.175 0l-2.8 2.034c-.784.57-1.838-.197-1.539-1.118l1.07-3.292a1 1 0 00-.364-1.118L2.98 8.72c-.783-.57-.38-1.81.588-1.81h3.461a1 1 0 00.951-.69l1.07-3.292z"/>
          </svg>`
        } else {
          btn.innerHTML = `<svg class="w-4 h-4 text-gray-300 hover:text-amber-300" fill="none" stroke="currentColor" stroke-width="1.5" viewBox="0 0 20 20">
            <path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.07 3.292a1 1 0 00.95.69h3.462c.969 0 1.371 1.24.588 1.81l-2.8 2.034a1 1 0 00-.364 1.118l1.07 3.292c.3.921-.755 1.688-1.54 1.118l-2.8-2.034a1 1 0 00-1.175 0l-2.8 2.034c-.784.57-1.838-.197-1.539-1.118l1.07-3.292a1 1 0 00-.364-1.118L2.98 8.72c-.783-.57-.38-1.81.588-1.81h3.461a1 1 0 00.951-.69l1.07-3.292z"/>
          </svg>`
        }
      })
    } catch (error) {
      console.error("Failed to toggle favorite:", error)
    }
  }

  // === Feature 2: Accordion Toggle ===
  toggleSection(event) {
    const button = event.currentTarget
    const section = button.closest("[data-order-builder-target='categorySection']")
    const content = section.querySelector("[data-order-builder-target='categoryContent']")
    const chevron = button.querySelector("[data-order-builder-target='chevron']")

    if (content.style.display === "none") {
      content.style.display = ""
      if (chevron) chevron.style.transform = ""
    } else {
      content.style.display = "none"
      if (chevron) chevron.style.transform = "rotate(-90deg)"
    }
  }
}
