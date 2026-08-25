import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["quantityInput", "lineTotal", "runningTotal", "itemCount", "supplierCount", "submitButton", "deliveryDate", "supplierCell", "searchInput", "searchClear", "categorySection", "mobileSupplierDetail", "uomToggle"]
  static values = { supplierMinimums: Object, deliverySchedules: Object, apiDeliveryDates: Object }

  connect() {
    this._buildMatchIndex()
    this._csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    this.updateTotals()
    this._setupFixedUI()

    // ORDERING SAFETY: the hidden quantity fields are normally written from
    // updateTotals(), which runs a frame or two after a change. Write them one
    // last time as the form goes, so what's submitted can never lag the model.
    this._orderForm = document.getElementById("order-form")
    if (this._orderForm) {
      this._submitHandler = () => this._serializeSelections()
      this._orderForm.addEventListener("submit", this._submitHandler)
    }
  }

  disconnect() {
    if (this._updateRAF) cancelAnimationFrame(this._updateRAF)
    if (this._scrollHandler) window.removeEventListener("scroll", this._scrollHandler)
    if (this._fixedBar) this._fixedBar.remove()
    if (this._floatingHeader) this._floatingHeader.remove()
    if (this._floatingCategory) this._floatingCategory.remove()
    if (this._scrollTopBtn) this._scrollTopBtn.remove()
    if (this._orderPanel) this._orderPanel.remove()
    if (this._orderForm && this._submitHandler) this._orderForm.removeEventListener("submit", this._submitHandler)
  }

  _setupFixedUI() {
    const cmdBar = document.getElementById("order-builder-command-bar")
    const thead = document.getElementById("order-builder-thead")
    const table = document.getElementById("order-builder-table")
    if (!cmdBar) return

    // Clone the command bar into a fixed div on document.body
    this._fixedBar = document.createElement("div")
    // Account for mobile tab bar height if present
    const tabBar = document.querySelector(".mobile-tab-bar")
    const tabBarHeight = tabBar ? tabBar.offsetHeight : 0
    this._tabBarHeight = tabBarHeight
    this._fixedBar.style.cssText = `position:fixed;bottom:${tabBarHeight}px;left:0;right:0;z-index:50;background:#3A6147;border-top:1px solid #2D5A3D;padding:0.25rem 1rem 0.5rem;`
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

    this._buildOrderPanel()

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
            this._fixedBar.style.bottom = (this._tabBarHeight || 0) + "px"
          }
        }

        this._positionOrderPanel()

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
    // Index supplier cells by match — the ring, the per-supplier counts and the
    // "ordered" fill all need every cell for a match (desktop card + in-page
    // mobile card render one each).
    this._matchCells = {}
    this._rowCache = {}
    // A product can be sourced from more than one supplier at once, so quantity
    // lives per (match, supplier) rather than per row:
    //   _sel[matchId][supplierId] = { qty, uom }
    // _primary[matchId] is the highlighted cell — the one +/- and typing feed.
    this._sel = {}
    this._primary = {}
    this.supplierCellTargets.forEach(cell => {
      const matchId = cell.dataset.matchId
      if (!matchId) return
      if (!this._matchCells[matchId]) this._matchCells[matchId] = []
      this._matchCells[matchId].push(cell)

      const supplierId = cell.dataset.supplierIdValue
      const qty = parseInt(cell.dataset.cellQty) || 0
      if (qty > 0 && supplierId) {
        if (!this._sel[matchId]) this._sel[matchId] = {}
        this._sel[matchId][supplierId] = { qty, uom: cell.dataset.currentUom || "CS" }
      }
      if (cell.dataset.default === "true" && supplierId) this._primary[matchId] = supplierId
    })
    // A row with quantities but no marked default still needs somewhere to aim
    // the + button.
    Object.keys(this._sel).forEach(matchId => {
      if (!this._primary[matchId]) this._primary[matchId] = Object.keys(this._sel[matchId])[0]
    })
    // Rows by match, for the order panel: it renders product names and thumbs
    // and scrolls back to whichever copy of a row is on screen.
    this._matchRows = {}
    this.element.querySelectorAll("[data-order-builder-row][data-match-id]").forEach(row => {
      const matchId = row.dataset.matchId
      if (!this._matchRows[matchId]) this._matchRows[matchId] = []
      this._matchRows[matchId].push(row)
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

  // The highlighted supplier receives +/-, typing, and Clear. Clicking a
  // different cell moves the highlight; it never moves an existing quantity.
  _primarySupplier(matchId) {
    if (this._primary[matchId]) return this._primary[matchId]
    const cell = this._matchCells?.[matchId]?.[0]
    if (cell) this._primary[matchId] = cell.dataset.supplierIdValue
    return this._primary[matchId]
  }

  _cellFor(matchId, supplierId) {
    return this._matchCells?.[matchId]?.find(c => c.dataset.supplierIdValue === supplierId)
  }

  // Set the highlighted supplier's quantity for this match. Other suppliers on
  // the same row keep theirs.
  _setPrimaryQuantity(matchId, value) {
    const supplierId = this._primarySupplier(matchId)
    if (!supplierId) return
    const qty = Math.max(0, value)
    if (!this._sel[matchId]) this._sel[matchId] = {}
    if (qty === 0) {
      delete this._sel[matchId][supplierId]
      if (Object.keys(this._sel[matchId]).length === 0) delete this._sel[matchId]
    } else {
      const cell = this._cellFor(matchId, supplierId)
      const existing = this._sel[matchId][supplierId]
      this._sel[matchId][supplierId] = {
        qty,
        uom: existing?.uom || cell?.dataset.currentUom || "CS"
      }
    }
  }

  _primaryQuantity(matchId) {
    const supplierId = this._primarySupplier(matchId)
    return this._sel[matchId]?.[supplierId]?.qty || 0
  }

  // The biggest line still on the row — where - falls through to once the
  // highlighted cell is empty.
  _largestLine(matchId) {
    const sel = this._sel[matchId]
    if (!sel) return null
    return Object.entries(sel)
      .filter(([, line]) => line.qty > 0)
      .sort((a, b) => b[1].qty - a[1].qty)[0]?.[0] || null
  }

  // Clear every supplier on the row, not just the highlighted one.
  _clearMatch(matchId) {
    delete this._sel[matchId]
  }

  // Render ONE row and return what it contributes to the page totals.
  // Cheap to call in a loop: when nothing about the row changed it replays the
  // cached numbers instead of touching the DOM, which matters because
  // updateTotals() walks every match on each keystroke.
  _renderMatch(matchId) {
    const sel = this._sel[matchId] || {}
    const primary = this._primarySupplier(matchId)
    const sig = `${primary}|` + Object.keys(sel).sort()
      .map(id => `${id}:${sel[id].qty}:${sel[id].uom}`).join(",")

    const cached = this._rowCache[matchId]
    if (cached && cached.sig === sig) return cached

    let total = 0
    let lineTotal = 0
    const perSupplier = {}
    // The page renders every row TWICE — the desktop card and the small-screen
    // card — so each supplier owns two cells. Both get redrawn; only one may
    // count toward the totals.
    const counted = new Set()

    this._matchCells?.[matchId]?.forEach(cell => {
      const supplierId = cell.dataset.supplierIdValue
      const qty = sel[supplierId]?.qty || 0
      const price = parseFloat(cell.dataset.supplierPrice) || 0

      // Each cell carries its own count, bottom-right, hidden at zero.
      const count = cell.querySelector("[data-cell-count]")
      if (count) {
        count.textContent = qty
        count.classList.toggle("hidden", qty === 0)
      }
      cell.dataset.cellQty = qty
      // Filled background means "ordered from here"; the ring means "the +
      // button feeds this one". They're independent now.
      cell.classList.toggle("bg-brand-orange-50", qty > 0)
      cell.classList.toggle("bg-gray-50", qty === 0)
      const isPrimary = supplierId === primary
      cell.classList.toggle("ring-2", isPrimary)
      cell.classList.toggle("ring-brand-orange", isPrimary)

      if (qty > 0 && !counted.has(supplierId)) {
        counted.add(supplierId)
        total += qty
        lineTotal += qty * price
        perSupplier[supplierId] = qty * price
      }
    })

    // The row's box shows the TOTAL across suppliers. Leave the one being typed
    // in alone — rewriting it mid-keystroke would fight the caret.
    this._matchInputs?.[matchId]?.forEach(input => {
      if (input === document.activeElement) return
      if (input.value !== String(total)) input.value = total
    })
    const text = lineTotal > 0 ? `$${lineTotal.toFixed(2)}` : "\u2014"
    this._matchLineTotals?.[matchId]?.forEach(el => el.textContent = text)

    const result = { sig, total, lineTotal, perSupplier }
    this._rowCache[matchId] = result
    return result
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

    // Walk each match ONCE (desktop + in-page mobile render the same row twice)
    // and let _renderMatch redraw it and hand back its contribution.
    Object.keys(this._matchInputs || {}).forEach(matchId => {
      if (seenMatches.has(matchId)) return
      seenMatches.add(matchId)

      const row = this._renderMatch(matchId)
      if (row.total <= 0) return

      total += row.lineTotal
      // A product split across two suppliers is still one item on the list.
      itemCount++
      Object.entries(row.perSupplier).forEach(([supplierId, amount]) => {
        supplierIds.add(supplierId)
        supplierTotals[supplierId] = (supplierTotals[supplierId] || 0) + amount
      })
    })

    // Keep the form's hidden fields in step with the model.
    this._serializeSelections()

    // Update Stimulus targets (original hidden bar)
    // The command bar renders each KPI TWICE — a narrow-screen row and a desktop
    // row — so these must be the plural targets. Writing only the singular one
    // updated the narrow copy and left the desktop copy at its "0" default,
    // which is what the clone below then froze in place on page load.
    this.runningTotalTargets.forEach(el => el.textContent = `$${total.toFixed(2)}`)
    this.itemCountTargets.forEach(el => el.textContent = itemCount)
    this.supplierCountTargets.forEach(el => el.textContent = supplierIds.size)

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

    // Update per-supplier delivery status badges
    this._updateDeliveryStatus(supplierTotals)

    // Keep the itemized panel honest while it's open
    this._renderOrderPanel()

    // Persist the working order (CurrentOrder) — skip the initial render so
    // page loads don't rewrite an unchanged state.
    if (this._initializedTotals) {
      this._syncCurrentOrder()
    } else {
      this._initializedTotals = true
    }
  }

  // The row's own box shows a total that may span suppliers, so it can't be the
  // form field. Write one hidden quantity per (match, supplier) instead.
  _serializeSelections() {
    const container = document.getElementById("order-selections")
    if (!container) return
    const parts = []
    Object.entries(this._sel).forEach(([matchId, bySupplier]) => {
      Object.entries(bySupplier).forEach(([supplierId, line]) => {
        if (!(line.qty > 0)) return
        parts.push(
          `<input type="hidden" name="quantities[${matchId}][${supplierId}]" value="${line.qty}">` +
          `<input type="hidden" name="uom_overrides[${matchId}][${supplierId}]" value="${line.uom || "CS"}">`
        )
      })
    })
    const html = parts.join("")
    // Rewriting identical markup on every keystroke would thrash the form.
    if (this._serializedHtml === html) return
    this._serializedHtml = html
    container.innerHTML = html
  }

  // ---- Working-order persistence (same contract as the mobile builder) ----

  _collectOrderState() {
    const state = {}
    Object.entries(this._sel).forEach(([matchId, bySupplier]) => {
      const lines = Object.entries(bySupplier)
        .filter(([, line]) => line.qty > 0)
        .map(([supplierId, line]) => ({ supplierId, qty: line.qty, uom: line.uom || "CS" }))
      if (lines.length) state[matchId] = lines
    })
    return state
  }

  _syncCurrentOrder() {
    clearTimeout(this._orderSyncTimer)
    this._orderSyncTimer = setTimeout(() => {
      const listId = window.location.pathname.match(/aggregated_lists\/(\d+)/)?.[1]
      if (!listId) return
      const allDates = [...(this._fixedDeliveryDates || []), ...(this.hasDeliveryDateTarget ? this.deliveryDateTargets : [])]
      fetch("/current_order", {
        method: "PUT",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": this._csrfToken },
        keepalive: true,
        body: JSON.stringify({
          aggregated_list_id: listId,
          state: this._collectOrderState(),
          delivery_date: allDates.find(d => d.value)?.value
        })
      }).catch(() => {})
    }, 500)
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

  _updateDeliveryStatus(supplierTotals) {
    const allDates = [...(this._fixedDeliveryDates || []), ...(this.hasDeliveryDateTarget ? this.deliveryDateTargets : [])]
    const dateVal = allDates.find(d => d.value)?.value
    const apiDates = this.apiDeliveryDatesValue || {}
    const schedules = this.deliverySchedulesValue || {}
    const dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    // Update all delivery status badges (original + cloned in fixed bar)
    document.querySelectorAll("[data-supplier-delivery-status]").forEach(badge => {
      const sid = badge.dataset.supplierDeliveryStatus
      const hasItems = supplierTotals && supplierTotals[sid] > 0
      const apiInfo = apiDates[sid]
      const schedList = schedules[sid]

      // Only show for suppliers with delivery info AND items selected
      if (!hasItems || (!apiInfo && !schedList)) {
        badge.classList.add("hidden")
        badge.textContent = ""
        return
      }

      badge.classList.remove("hidden")

      if (!dateVal) {
        // No date selected yet — show available days summary
        if (apiInfo && apiInfo.dates && apiInfo.dates.length > 0) {
          const nextDate = apiInfo.dates[0]
          badge.textContent = `Next: ${this._formatShortDate(nextDate)}`
          badge.className = badge.className.replace(/text-\S+/g, "")
          badge.classList.add("text-gray-500")
        } else if (schedList) {
          const days = schedList.map(s => dayNames[s.day].substring(0, 3)).join("/")
          badge.textContent = `Delivers ${days}`
          badge.className = badge.className.replace(/text-\S+/g, "")
          badge.classList.add("text-gray-500")
        }
        return
      }

      // Date selected — check if it's valid
      if (apiInfo && apiInfo.dates) {
        if (apiInfo.dates.includes(dateVal)) {
          badge.textContent = `\u2713 Delivers ${this._formatShortDate(dateVal)}`
          badge.className = badge.className.replace(/text-\S+/g, "")
          badge.classList.add("text-green-600")
        } else {
          const next = apiInfo.dates.find(d => d > dateVal)
          badge.textContent = next
            ? `\u26A0 No delivery \u2014 next: ${this._formatShortDate(next)}`
            : "\u26A0 No delivery dates available"
          badge.className = badge.className.replace(/text-\S+/g, "")
          badge.classList.add("text-amber-600")
        }
      } else if (schedList) {
        const selected = new Date(dateVal + "T00:00:00")
        const selectedDay = selected.getDay()
        const validDays = schedList.map(s => s.day)

        if (validDays.includes(selectedDay)) {
          const sched = schedList.find(s => s.day === selectedDay)
          badge.textContent = `\u2713 Delivers ${dayNames[selectedDay].substring(0, 3)}`
          if (sched) badge.textContent += ` \u00B7 order by ${sched.cutoff_day_name.substring(0, 3)} ${this._formatTime(sched.cutoff_time)}`
          badge.className = badge.className.replace(/text-\S+/g, "")
          badge.classList.add("text-green-600")
        } else {
          const nextDay = this._nextValidDay(selected, validDays)
          badge.textContent = `\u26A0 No delivery ${dayNames[selectedDay].substring(0, 3)} \u2014 next: ${this._formatShortDate(nextDay)}`
          badge.className = badge.className.replace(/text-\S+/g, "")
          badge.classList.add("text-amber-600")
        }
      }
    })
  }

  _formatShortDate(isoStr) {
    const d = new Date(isoStr + "T00:00:00")
    return d.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" })
  }

  _formatTime(timeStr) {
    const [h, m] = timeStr.split(":").map(Number)
    const ampm = h >= 12 ? "pm" : "am"
    const h12 = h % 12 || 12
    return m === 0 ? `${h12}${ampm}` : `${h12}:${m.toString().padStart(2, "0")}${ampm}`
  }

  _nextValidDay(fromDate, validDays) {
    const d = new Date(fromDate)
    for (let i = 1; i <= 7; i++) {
      d.setDate(d.getDate() + 1)
      if (validDays.includes(d.getDay())) {
        return d.toISOString().split("T")[0]
      }
    }
    return null
  }

  // Clicking a cell aims the +/- controls at that supplier. It deliberately does
  // NOT carry an existing quantity over: a chef ordering 5 salads from PPO and
  // clicking WCW wants to add one there, not move all five.
  selectSupplier(event) {
    const cell = event.currentTarget
    const matchId = cell.dataset.matchId
    this._primary[matchId] = cell.dataset.supplierIdValue

    this._renderMatch(matchId)
    this._scheduleUpdateTotals()
  }

  selectUom(event) {
    event.preventDefault()
    event.stopPropagation() // Don't trigger selectSupplier on the parent cell

    const btn = event.currentTarget
    const uom = btn.dataset.uom                     // "CS" or "PC"
    const uomPrice = parseFloat(btn.dataset.uomPrice) || 0
    const matchId = btn.dataset.matchId
    const supplierId = btn.dataset.supplierId

    // Update the toggle button styles within this toggle group
    const toggleContainer = btn.closest("[data-order-builder-target='uomToggle']")
    if (toggleContainer) {
      toggleContainer.querySelectorAll("button").forEach(b => {
        if (b.dataset.uom === uom) {
          b.classList.remove("text-gray-500", "bg-transparent")
          b.classList.add("bg-gray-200", "text-gray-900", "font-medium")
        } else {
          b.classList.remove("bg-gray-200", "text-gray-900", "font-medium")
          b.classList.add("text-gray-500", "bg-transparent")
        }
      })
    }

    // Update the supplier cell's price display
    const cell = btn.closest("[data-order-builder-target='supplierCell']")
    if (cell) {
      cell.dataset.supplierPrice = uomPrice
      cell.dataset.currentUom = uom

      // Update price text
      const priceSpan = cell.querySelector("[data-price-label]")
      if (priceSpan) {
        // Preserve any arrow icons
        const arrow = priceSpan.querySelector("span")
        priceSpan.textContent = `$${uomPrice.toFixed(2)}`
        if (arrow) priceSpan.appendChild(arrow)
      }

      // Update pack size text
      const packDiv = cell.querySelector("[data-pack-size]")
      if (packDiv) {
        const packSize = btn.dataset.uomPackSize
        if (packSize) packDiv.textContent = packSize
      }

      // Update per-unit price text
      const perUnitText = btn.dataset.uomPerUnit
      const perUnitSpan = cell.querySelector("[data-per-unit-price]")
      if (perUnitSpan && perUnitText) {
        perUnitSpan.textContent = perUnitText
      }

      // Handle "Best" badge: hide when switching to PC (apples-to-oranges),
      // restore when switching back to CS if this cell was originally cheapest
      // BEST is carried by the pill alone now. Hide it on PC (apples-to-oranges
      // against the other cells' case prices) and restore it on CS.
      if (cell.dataset.cheapest === "true") {
        const badge = cell.querySelector("[data-best-badge]")
        if (badge) badge.classList.toggle("hidden", uom === "PC")
      }
    }

    // CS/PC is per supplier, not per row — one product can be cases from one
    // supplier and pieces from another. _serializeSelections writes it out.
    if (this._sel[matchId]?.[supplierId]) this._sel[matchId][supplierId].uom = uom

    this._renderMatch(matchId)
    this._scheduleUpdateTotals()
  }

  _rowMatchId(event) {
    return event.currentTarget.closest("[data-order-builder-row]")
      ?.querySelector("[data-order-builder-target='quantityInput']")?.dataset.matchId
  }

  increment(event) {
    const matchId = this._rowMatchId(event)
    if (!matchId) return
    this._setPrimaryQuantity(matchId, this._primaryQuantity(matchId) + 1)
    // Instant visual feedback; defer the heavy KPI recalc to the next frame
    this._renderMatch(matchId)
    this._scheduleUpdateTotals()
  }

  decrement(event) {
    const matchId = this._rowMatchId(event)
    if (!matchId) return
    // The highlighted cell can be empty while the row still has quantity on
    // another supplier. Rather than going inert — a dead button under a row
    // that plainly shows a total — walk down what's left, and take the
    // highlight with it so the next + lands where the last - came from.
    if (this._primaryQuantity(matchId) <= 0) {
      const fallback = this._largestLine(matchId)
      if (!fallback) return
      this._primary[matchId] = fallback
    }
    this._setPrimaryQuantity(matchId, this._primaryQuantity(matchId) - 1)
    this._renderMatch(matchId)
    this._scheduleUpdateTotals()
  }

  // Clear empties the whole row, every supplier on it — not just the highlighted
  // one, which would leave a confusing remainder behind.
  clearQuantity(event) {
    const matchId = this._rowMatchId(event)
    if (!matchId) return
    this._clearMatch(matchId)
    this._renderMatch(matchId)
    this._scheduleUpdateTotals()
  }

  // Typing goes to the highlighted supplier, same rule as +/-. On a row split
  // across suppliers the box then re-renders to the new total.
  quantityTyped(event) {
    const matchId = event.currentTarget.dataset.matchId
    if (!matchId) return
    this._setPrimaryQuantity(matchId, parseInt(event.currentTarget.value) || 0)
    this._scheduleUpdateTotals()
  }

  // On the way out, snap the box to the row's real total (which on a split row
  // is more than what was just typed).
  quantityBlurred(event) {
    const matchId = event.currentTarget.dataset.matchId
    if (!matchId) return
    delete this._rowCache[matchId]
    this._renderMatch(matchId)
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

  // Desktop had no itemized view of the order at all: the bar showed a count and
  // a total, so a line added weeks ago stayed invisible unless you happened to
  // scroll past its row. This panel is that missing list, grouped by supplier so
  // "why is Chef's Warehouse at $25?" is answerable at a glance.
  _buildOrderPanel() {
    this._orderPanel = document.createElement("div")
    this._orderPanel.style.cssText =
      "position:fixed;left:0;right:0;z-index:49;display:none;background:#fff;" +
      "border-top:1px solid #e5e7eb;box-shadow:0 -8px 24px rgba(0,0,0,0.12);" +
      "max-height:min(60vh,32rem);overflow-y:auto;"
    document.body.appendChild(this._orderPanel)

    // The panel lives outside the controller's element, so data-action never
    // fires here — delegate from the container instead.
    this._orderPanel.addEventListener("click", (event) => {
      const btn = event.target.closest("[data-panel-action]")
      if (btn) {
        const { panelAction, matchId, supplierId } = btn.dataset
        if (panelAction === "close") return this.toggleOrderPanel()
        this._primary[matchId] = supplierId
        if (panelAction === "remove") {
          this._setPrimaryQuantity(matchId, 0)
        } else {
          const current = this._sel[matchId]?.[supplierId]?.qty || 0
          this._setPrimaryQuantity(matchId, current + (panelAction === "increment" ? 1 : -1))
        }
        this._renderMatch(matchId)
        this.updateTotals()
        return
      }
      const line = event.target.closest("[data-panel-line]")
      if (line) this._jumpToMatch(line.dataset.matchId)
    })

    this._fixedBar.querySelectorAll("[data-order-panel-toggle]").forEach(el => {
      el.addEventListener("click", () => this.toggleOrderPanel())
    })
  }

  toggleOrderPanel() {
    if (!this._orderPanel) return
    this._orderPanelOpen = !this._orderPanelOpen
    if (this._orderPanelOpen) this._renderOrderPanel()
    this._orderPanel.style.display = this._orderPanelOpen ? "block" : "none"
    this._positionOrderPanel()
  }

  _positionOrderPanel() {
    if (!this._orderPanel || !this._orderPanelOpen) return
    this._orderPanel.style.bottom = (this._fixedBar?.offsetHeight || 0) +
      (parseFloat(this._fixedBar?.style.bottom) || 0) + "px"
  }

  // Scroll the grid to a product and flash it, so a line in the panel leads
  // back to the row it came from.
  _jumpToMatch(matchId) {
    const row = this._matchRows?.[matchId]?.find(r => r.offsetParent !== null)
    if (!row) return
    if (this._orderPanelOpen) this.toggleOrderPanel()
    row.scrollIntoView({ behavior: "smooth", block: "center" })
    row.classList.add("ring-2", "ring-brand-orange")
    setTimeout(() => row.classList.remove("ring-2", "ring-brand-orange"), 1600)
  }

  _renderOrderPanel() {
    if (!this._orderPanel || !this._orderPanelOpen) return
    const minimums = this.supplierMinimumsValue || {}

    // Group by supplier: the totals in the bar are per supplier, so the list
    // that explains them should be too.
    const bySupplier = {}
    Object.entries(this._sel).forEach(([matchId, lines]) => {
      Object.entries(lines).forEach(([supplierId, line]) => {
        if (!(line.qty > 0)) return
        const cell = this._cellFor(matchId, supplierId)
        const row = this._matchRows?.[matchId]?.[0]
        if (!cell || !row) return
        const price = parseFloat(cell.dataset.supplierPrice) || 0
        ;(bySupplier[supplierId] ||= []).push({
          matchId, supplierId, qty: line.qty, uom: line.uom, price,
          name: row.dataset.displayName || "",
          thumb: row.dataset.thumb || ""
        })
      })
    })

    const supplierIds = Object.keys(bySupplier)
    if (supplierIds.length === 0) {
      this._orderPanel.innerHTML = `
        <div style="max-width:72rem;margin:0 auto;" class="px-4 py-8 text-center text-sm text-gray-500">
          Nothing in this order yet.
        </div>`
      return
    }

    const groups = supplierIds.map(supplierId => {
      const lines = bySupplier[supplierId]
      const config = minimums[supplierId] || {}
      const subtotal = lines.reduce((sum, l) => sum + l.price * l.qty, 0)
      const min = config.minimum
      const short = this._supplierShortName(supplierId)
      const minLabel = min > 0
        ? (subtotal >= min
            ? `<span class="text-brand-green font-semibold">&#10003; $${min.toFixed(0)} minimum met</span>`
            : `<span class="text-brand-orange font-semibold">$${(min - subtotal).toFixed(2)} to reach the $${min.toFixed(0)} minimum</span>`)
        : `<span class="text-gray-400">No minimum</span>`

      return `
        <div class="border-b border-gray-100 last:border-b-0">
          <div class="flex items-baseline justify-between gap-3 px-4 pt-3 pb-1.5">
            <span class="text-xs font-bold uppercase tracking-wide text-gray-700">${short}</span>
            <span class="text-[11px]">${minLabel}</span>
            <span class="ml-auto text-sm font-bold text-gray-900">$${subtotal.toFixed(2)}</span>
          </div>
          ${lines.map(l => this._orderPanelLine(l)).join("")}
        </div>`
    }).join("")

    this._orderPanel.innerHTML = `
      <div style="max-width:72rem;margin:0 auto;">
        <div class="flex items-center justify-between px-4 py-2 border-b border-gray-200 sticky top-0 bg-white">
          <span class="text-sm font-bold text-gray-900">In this order</span>
          <button type="button" data-panel-action="close"
                  class="text-xs font-semibold text-gray-500 hover:text-gray-900 px-2 py-1">Close</button>
        </div>
        ${groups}
      </div>`
  }

  _orderPanelLine(l) {
    const stepper = (action, label) =>
      `<button type="button" data-panel-action="${action}" data-match-id="${l.matchId}" data-supplier-id="${l.supplierId}"
               class="w-7 h-7 rounded-md border border-gray-300 text-gray-600 hover:bg-gray-100 text-sm leading-none">${label}</button>`

    return `
      <div data-panel-line data-match-id="${l.matchId}"
           class="flex items-center gap-3 px-4 py-2 cursor-pointer hover:bg-gray-50">
        <img src="${l.thumb}" alt="" class="w-9 h-9 rounded-md object-cover border border-gray-200 bg-gray-50 shrink-0">
        <div class="min-w-0 flex-1">
          <div class="text-sm text-gray-900 truncate">${l.name}</div>
          <div class="text-[11px] text-gray-500">$${l.price.toFixed(2)}${l.uom === "PC" ? " / PC" : " / CS"}</div>
        </div>
        <div class="flex items-center gap-1 shrink-0">
          ${stepper("decrement", "&minus;")}
          <span class="w-7 text-center text-sm font-bold text-gray-900">${l.qty}</span>
          ${stepper("increment", "+")}
        </div>
        <span class="w-20 text-right text-sm font-bold text-gray-900 shrink-0">$${(l.price * l.qty).toFixed(2)}</span>
        <button type="button" data-panel-action="remove" data-match-id="${l.matchId}" data-supplier-id="${l.supplierId}"
                title="Remove" class="shrink-0 w-7 h-7 rounded-md text-gray-400 hover:text-red-500 hover:bg-red-50 text-sm leading-none">&times;</button>
      </div>`
  }

  _supplierShortName(supplierId) {
    if (!this._supplierNames) {
      this._supplierNames = {}
      this.supplierCellTargets.forEach(cell => {
        const label = cell.querySelector("[data-supplier-label]")
        if (label) this._supplierNames[cell.dataset.supplierIdValue] = label.textContent.trim()
      })
    }
    return this._supplierNames[supplierId] ||
      (this.supplierMinimumsValue || {})[supplierId]?.name || "Supplier"
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

  // Swallow Enter on inputs so a stray keypress in the search/date/quantity
  // fields can't submit the order to the verify page. The submit button stays
  // the only way to advance — chefs press Enter all the time without meaning to.
  preventEnterSubmit(event) {
    if (event.key !== "Enter") return
    if (event.target.tagName === "INPUT") event.preventDefault()
  }

  // === Feature 1: Search/Filter ===
  clearSearch() {
    if (!this.hasSearchInputTarget) return
    this.searchInputTarget.value = ""
    this.filterProducts()
    this.searchInputTarget.focus()
  }

  filterProducts() {
    const query = this.hasSearchInputTarget ? this.searchInputTarget.value.toLowerCase().trim() : ""
    if (this.hasSearchClearTarget) this.searchClearTarget.classList.toggle("hidden", query === "")

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
