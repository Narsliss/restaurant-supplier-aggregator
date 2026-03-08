import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["quantityInput", "lineTotal", "runningTotal", "itemCount", "supplierCount", "submitButton", "deliveryDate", "supplierCell", "searchInput", "categorySection", "mobileSupplierDetail"]
  static values = { supplierMinimums: Object }

  connect() {
    this._buildMatchIndex()
    this._csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    this.updateTotals()
    this._setupFixedUI()
  }

  disconnect() {
    if (this._updateRAF) cancelAnimationFrame(this._updateRAF)
    if (this._scrollHandler) window.removeEventListener("scroll", this._scrollHandler)
    if (this._fixedBar) this._fixedBar.remove()
    if (this._floatingHeader) this._floatingHeader.remove()
    if (this._floatingCategory) this._floatingCategory.remove()
    if (this._scrollTopBtn) this._scrollTopBtn.remove()
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

    // Floating table header + floating category label
    const nav = document.querySelector("nav")

    if (thead && table) {
      this._floatingHeader = document.createElement("div")
      this._floatingHeader.style.cssText = "position:fixed;top:0;left:0;right:0;z-index:40;display:none;background:#3A6147;border-bottom:1px solid #2D5A3D;"
      document.body.appendChild(this._floatingHeader)

      this._floatingCategory = document.createElement("div")
      this._floatingCategory.style.cssText = "position:fixed;left:0;right:0;z-index:39;display:none;background:#f9fafb;border-bottom:1px solid #e5e7eb;padding:0.5rem 1rem;"
      document.body.appendChild(this._floatingCategory)

      // Scroll-to-top button
      this._scrollTopBtn = document.createElement("button")
      this._scrollTopBtn.innerHTML = `<svg class="w-5 h-5" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" d="M5 15l7-7 7 7"/></svg>`
      this._scrollTopBtn.style.cssText = "position:fixed;right:1.5rem;z-index:51;width:2.5rem;height:2.5rem;border-radius:9999px;background:#3A6147;color:white;border:none;cursor:pointer;display:flex;align-items:center;justify-content:center;box-shadow:0 2px 8px rgba(0,0,0,0.2);opacity:0;pointer-events:none;transition:opacity 0.2s;"
      this._scrollTopBtn.addEventListener("click", () => window.scrollTo({ top: 0, behavior: "smooth" }))
      document.body.appendChild(this._scrollTopBtn)

      this._scrollHandler = () => {
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

        // Floating category label — tracks current section while scrolling
        const headerVisible = this._floatingHeader.style.display === "block"
        const headerBottom = headerVisible
          ? this._floatingHeader.getBoundingClientRect().bottom
          : navBottom

        let currentCategoryHtml = null
        const categorySections = this._cachedCategorySections || this.categorySectionTargets
        categorySections.forEach(section => {
          if (section.tagName === "TR") {
            const rect = section.getBoundingClientRect()
            if (rect.top <= headerBottom + 2) {
              currentCategoryHtml = section.querySelector("td").innerHTML
            }
          }
        })

        if (currentCategoryHtml && headerVisible && tableRect.bottom > headerBottom) {
          this._floatingCategory.style.top = headerBottom + "px"
          this._floatingCategory.style.left = tableRect.left + "px"
          this._floatingCategory.style.right = (window.innerWidth - tableRect.right) + "px"
          this._floatingCategory.innerHTML = currentCategoryHtml
          this._floatingCategory.style.display = "block"
        } else {
          this._floatingCategory.style.display = "none"
        }

        // Stop the bottom bar at the footer so it doesn't cover it
        const footer = document.querySelector("footer")
        if (footer) {
          const footerTop = footer.getBoundingClientRect().top
          if (footerTop < window.innerHeight) {
            this._fixedBar.style.bottom = (window.innerHeight - footerTop) + "px"
          } else {
            this._fixedBar.style.bottom = "0"
          }
        }

        // Show scroll-to-top button after scrolling past one viewport height
        if (this._scrollTopBtn) {
          const barBottom = parseFloat(this._fixedBar.style.bottom) || 0
          this._scrollTopBtn.style.bottom = (barBottom + this._fixedBar.offsetHeight + 12) + "px"
          if (window.scrollY > window.innerHeight) {
            this._scrollTopBtn.style.opacity = "1"
            this._scrollTopBtn.style.pointerEvents = "auto"
          } else {
            this._scrollTopBtn.style.opacity = "0"
            this._scrollTopBtn.style.pointerEvents = "none"
          }
        }
      }

      window.addEventListener("scroll", this._scrollHandler, { passive: true })
    }
  }

  // Build O(1) lookup maps: matchId → [inputs] and matchId → [lineTotals]
  // Also caches the full target arrays — each access of this.xxxTargets in Stimulus
  // runs querySelectorAll on the entire DOM, which is catastrophic inside loops.
  _buildMatchIndex() {
    this._matchInputs = {}
    this._matchLineTotals = {}
    // Cache these ONCE — avoids 2000+ querySelectorAll calls in updateTotals()
    this._cachedQuantityInputs = this.quantityInputTargets
    this._cachedLineTotals = this.lineTotalTargets
    this._cachedQuantityInputs.forEach((input, index) => {
      const matchId = input.dataset.matchId
      if (matchId) {
        if (!this._matchInputs[matchId]) this._matchInputs[matchId] = []
        this._matchInputs[matchId].push(input)
        if (this._cachedLineTotals[index]) {
          if (!this._matchLineTotals[matchId]) this._matchLineTotals[matchId] = []
          this._matchLineTotals[matchId].push(this._cachedLineTotals[index])
        }
      }
    })
    // Cache category sections for scroll handler (fires every scroll event)
    this._cachedCategorySections = this.categorySectionTargets
    // Also cache supplier breakdown original elements (avoid querySelectorAll per supplier per click)
    this._origSupplierCards = {}
    this._origSupplierSubtotals = {}
    this._origSupplierProgressBars = {}
    this._origSupplierMinLabels = {}
    this.element.querySelectorAll("[data-supplier-breakdown-id]").forEach(el => {
      const id = el.dataset.supplierBreakdownId
      if (!this._origSupplierCards[id]) this._origSupplierCards[id] = []
      this._origSupplierCards[id].push(el)
    })
    this.element.querySelectorAll("[data-supplier-subtotal]").forEach(el => {
      const id = el.dataset.supplierSubtotal
      if (!this._origSupplierSubtotals[id]) this._origSupplierSubtotals[id] = []
      this._origSupplierSubtotals[id].push(el)
    })
    this.element.querySelectorAll("[data-supplier-progress-bar]").forEach(el => {
      const id = el.dataset.supplierProgressBar
      if (!this._origSupplierProgressBars[id]) this._origSupplierProgressBars[id] = []
      this._origSupplierProgressBars[id].push(el)
    })
    this.element.querySelectorAll("[data-supplier-minimum-label]").forEach(el => {
      const id = el.dataset.supplierMinimumLabel
      if (!this._origSupplierMinLabels[id]) this._origSupplierMinLabels[id] = []
      this._origSupplierMinLabels[id].push(el)
    })
  }

  // Set the value for ALL inputs sharing the same match ID (desktop + mobile)
  // Uses index map for O(1) lookup instead of scanning all targets
  _setMatchQuantity(matchId, value) {
    const inputs = this._matchInputs?.[matchId]
    if (inputs) {
      inputs.forEach(input => input.value = value)
    } else {
      // Fallback if index not built yet
      this.quantityInputTargets.forEach(input => {
        if (input.dataset.matchId === matchId) input.value = value
      })
    }
  }

  // Instantly update the line total for ONE match — gives immediate visual feedback
  _updateMatchLineTotal(matchId) {
    const inputs = this._matchInputs?.[matchId]
    if (!inputs?.length) return
    const input = inputs[0]
    const qty = parseInt(input.value) || 0
    const price = parseFloat(input.dataset.price) || 0
    const lineTotal = qty * price
    const text = lineTotal > 0 ? `$${lineTotal.toFixed(2)}` : "\u2014"
    const totals = this._matchLineTotals?.[matchId]
    if (totals) totals.forEach(el => el.textContent = text)
  }

  // Defer heavy KPI recalculation AFTER the browser paints.
  // Single RAF runs BEFORE paint — so we use double-RAF:
  //   1st RAF → runs before paint → schedules 2nd RAF
  //   Browser paints (user sees instant qty + line total change)
  //   2nd RAF → runs updateTotals() with KPI recalc
  _scheduleUpdateTotals() {
    if (this._updateRAF) cancelAnimationFrame(this._updateRAF)
    this._updateRAF = requestAnimationFrame(() => {
      this._updateRAF = requestAnimationFrame(() => {
        this._updateRAF = null
        this.updateTotals()
      })
    })
  }

  updateTotals() {
    let total = 0
    let itemCount = 0
    const supplierIds = new Set()
    const supplierTotals = {}
    const seenMatches = new Set()

    // Use cached arrays — NOT this.quantityInputTargets / this.lineTotalTargets!
    // Each Stimulus getter calls querySelectorAll on the entire DOM.
    // Inside a loop of 1000, that's 2000+ full DOM scans = ~1 second of lag.
    const inputs = this._cachedQuantityInputs || this.quantityInputTargets
    const lineTotals = this._cachedLineTotals || this.lineTotalTargets

    inputs.forEach((input, index) => {
      const matchId = input.dataset.matchId
      const qty = parseInt(input.value) || 0
      const price = parseFloat(input.dataset.price) || 0
      const supplierId = input.dataset.supplierId
      const lineTotal = qty * price

      // Update the line total display for this row
      if (lineTotals[index]) {
        lineTotals[index].textContent = lineTotal > 0
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
    const matchInputs = this._matchInputs?.[matchId] || []
    matchInputs.forEach(input => {
      input.dataset.price = newPrice
      input.dataset.supplierId = newSupplierId
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

    this._updateMatchLineTotal(matchId)
    this._scheduleUpdateTotals()
  }

  increment(event) {
    const input = event.currentTarget.closest("[data-order-builder-row]").querySelector("[data-order-builder-target='quantityInput']")
    const newValue = (parseInt(input.value) || 0) + 1
    const matchId = input.dataset.matchId
    // Instant visual feedback: update input + line total immediately
    this._setMatchQuantity(matchId, newValue)
    this._updateMatchLineTotal(matchId)
    // Defer heavy KPI recalc to next frame so browser paints the change first
    this._scheduleUpdateTotals()
  }

  decrement(event) {
    const input = event.currentTarget.closest("[data-order-builder-row]").querySelector("[data-order-builder-target='quantityInput']")
    const current = parseInt(input.value) || 0
    if (current > 0) {
      const newValue = current - 1
      const matchId = input.dataset.matchId
      this._setMatchQuantity(matchId, newValue)
      this._updateMatchLineTotal(matchId)
      this._scheduleUpdateTotals()
    }
  }

  clearQuantity(event) {
    const input = event.currentTarget.closest("[data-order-builder-row]").querySelector("[data-order-builder-target='quantityInput']")
    const matchId = input.dataset.matchId
    this._setMatchQuantity(matchId, 0)
    this._updateMatchLineTotal(matchId)
    this._scheduleUpdateTotals()
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
        ...(this._origSupplierCards?.[supplierId] || []),
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
        ...(this._origSupplierSubtotals?.[supplierId] || []),
        ...(this._fixedSupplierSubtotals?.[supplierId] || [])
      ]
      subtotalEls.forEach(el => el.textContent = formattedSubtotal)

      // Update progress bar and colors
      if (minimum && minimum > 0) {
        const percent = Math.min(100, (subtotal / minimum) * 100)
        const met = subtotal >= minimum

        const progressEls = [
          ...(this._origSupplierProgressBars?.[supplierId] || []),
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
          ...(this._origSupplierMinLabels?.[supplierId] || []),
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
        const category = section.dataset.category
        // On desktop, product rows are siblings with matching data-category
        // On mobile, product rows are descendants of the section
        const descendantRows = section.querySelectorAll("[data-order-builder-row]:not([style*='display: none'])")
        if (descendantRows.length > 0) {
          section.style.display = ""
          return
        }
        // Desktop: check sibling rows with matching category
        const siblingRows = this.element.querySelectorAll(`[data-order-builder-row][data-category="${category}"]:not([style*='display: none'])`)
        section.style.display = siblingRows.length === 0 ? "none" : ""
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

    try {
      const response = await fetch("/favorite_products/toggle", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrfToken,
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

  // === Feature 2: (removed — accordions replaced with flat category headers) ===
}
