import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "quantityInput", "lineTotal", "itemRow", "orderCard",
    "orderSubtotal", "orderSubtotalFooter", "orderItemCount",
    "summaryOrders", "summaryItems", "summaryTotal", "summarySavings",
    "minimumBadge", "minimumWarning", "minimumShortfall",
    "caseMinimumWarning", "caseMinimumShortfall", "caseMinimumBadge",
    "warningsArea", "submitAllBtn", "supplierSubmitBtn", "summaryBar",
    "deliveryDate", "deliveryAddress", "deliveryRow", "deliveryDateLabel",
    "deliveryDateWarning", "deliveryDateRequired",
    // Verification targets
    "verificationBanner", "verificationProgress",
    "priceChangeBanner", "verificationFailedBanner", "verificationFailedMessage",
    "verifyingIndicator", "verifiedBadge", "priceChangedBadge", "verifyFailedBadge",
    "priceChangeDetails", "priceChangeList", "priceDiff", "unitPriceDisplay",
    "verificationErrorDetails", "verificationErrorText",
    "suggestionsSection", "draftBanner",
    // Forgot Something modal
    "forgotModal", "forgotSearchInput", "forgotResults",
    // Delivery hints
    "deliveryHint"
  ]

  static values = {
    batchId: String,
    verifying: Boolean,
    aggregatedListId: String,
    deliveryInfo: Object
  }

  connect() {
    this._debounceTimers = {}
    this._pollingInterval = null
    this._recalcRAF = null
    this._cachedCsrfToken = null
    this._draftNotificationShown = false
    this._verifyingLocked = false
    this._updateSubmitStates()
    this._initDeliveryHints()

    // Always start polling — verification may complete before the page finishes
    // loading (race condition), so poll regardless of initial verifying state.
    // Polling stops itself once all orders are settled.
    this._startPolling()
  }

  disconnect() {
    this._stopPolling()
    if (this._recalcRAF) cancelAnimationFrame(this._recalcRAF)
  }

  // --- Quantity adjustments ---

  incrementItem(event) {
    if (this._verifyingLocked) return
    const btn = event.currentTarget
    const itemId = btn.dataset.itemId
    const input = this._inputForItem(itemId)
    if (!input) return
    const newQty = (parseInt(input.value) || 0) + 1
    input.value = newQty
    this._onQuantityChange(itemId, btn.dataset.orderId, newQty)
  }

  decrementItem(event) {
    if (this._verifyingLocked) return
    const btn = event.currentTarget
    const itemId = btn.dataset.itemId
    const input = this._inputForItem(itemId)
    if (!input) return
    const current = parseInt(input.value) || 0
    if (current <= 1) return // minimum quantity is 1
    const newQty = current - 1
    input.value = newQty
    this._onQuantityChange(itemId, btn.dataset.orderId, newQty)
  }

  updateQuantity(event) {
    if (this._verifyingLocked) return
    const input = event.currentTarget
    const newQty = parseInt(input.value) || 1
    if (newQty < 1) {
      input.value = 1
      return
    }
    this._onQuantityChange(input.dataset.itemId, input.dataset.orderId, newQty)
  }

  _onQuantityChange(itemId, orderId, quantity) {
    // Sync quantity across desktop + mobile duplicate inputs for this item
    this.quantityInputTargets.forEach(input => {
      if (input.dataset.itemId === itemId) {
        input.value = quantity
      }
    })

    // Instant line-total update (lightweight — no layout reads)
    this._updateLineTotal(itemId, quantity)

    // Defer heavy recalculations to next animation frame so the browser
    // can paint the input + line-total changes immediately.
    // With ~500 items (1000 DOM rows for desktop+mobile), the full
    // recalculation is too expensive to run synchronously on every click.
    this._scheduleRecalculation()

    // Debounced server persist
    this._debouncePatch(itemId, orderId, quantity)
  }

  _updateLineTotal(itemId, quantity) {
    // Find unit price from any row for this item (desktop or mobile)
    let unitPrice = 0
    this.itemRowTargets.forEach(row => {
      if (row.dataset.itemId === itemId && parseFloat(row.dataset.unitPrice)) {
        unitPrice = parseFloat(row.dataset.unitPrice)
      }
    })
    const lineTotal = unitPrice * quantity

    // Update ALL line total displays for this item (desktop + mobile)
    this.lineTotalTargets.forEach(el => {
      if (el.dataset.itemId === itemId) {
        el.textContent = this._formatCurrency(lineTotal)
      }
    })
  }

  // --- Remove item ---

  removeItem(event) {
    if (this._verifyingLocked) return
    const btn = event.currentTarget
    const itemId = btn.dataset.itemId
    const orderId = btn.dataset.orderId

    // Remove from DOM immediately
    this.itemRowTargets.forEach(row => {
      if (row.dataset.itemId === itemId) {
        row.remove()
      }
    })

    // Check if order card has no items left
    const card = this._cardForOrder(orderId)
    if (card) {
      const remaining = card.querySelectorAll("[data-order-review-target='itemRow']").length
      if (remaining === 0) {
        card.remove()
      } else {
        // If no more out-of-stock items remain, clear the unavailable banner
        if (!card.querySelector("[data-in-stock='false']")) {
          const banner = card.querySelector(".unavailable-banner")
          if (banner) banner.remove()
        }
      }
    }

    // Defer all recalculation to next frame (single pass)
    this._scheduleRecalculation()

    // Server DELETE
    this._deleteItem(itemId, orderId)
  }

  // --- Delivery date / notes ---

  updateDeliveryDate(event) {
    const input = event.currentTarget
    const orderId = input.dataset.orderId
    this._patchOrder(orderId, { delivery_date: input.value })
    this._clearDeliveryDateWarning(orderId, input)
    this._updateDeliveryHint(orderId, input.value)
    this._updateSubmitStates()
  }

  updateNotes(event) {
    const input = event.currentTarget
    const orderId = input.dataset.orderId
    this._patchOrder(orderId, { notes: input.value })
  }

  // --- Quick-add suggestions ---

  addSuggestion(event) {
    if (this._verifyingLocked) return
    const btn = event.currentTarget
    const orderId = String(btn.dataset.orderId)
    const supplierProductId = btn.dataset.supplierProductId

    // Disable immediately to prevent double-click
    btn.disabled = true
    btn.classList.add("opacity-50", "cursor-not-allowed")

    fetch(`/orders/${orderId}/order_items`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this._csrfToken(),
        "Accept": "application/json"
      },
      body: JSON.stringify({ supplier_product_id: supplierProductId, quantity: 1 })
    })
    .then(res => {
      if (!res.ok) throw new Error("Failed to add item")
      return res.json()
    })
    .then(data => {
      if (data.is_existing) {
        this._updateExistingItemRow(data.item)
      } else {
        this._insertNewItemRow(orderId, data.item, data.item.verification_pending)
      }

      // Remove the suggestion pill
      btn.remove()

      // Update order totals from server response (most accurate)
      this._applyServerTotals(orderId, data.order)

      // Recalculate summary bar
      this._recalculateSummary()

      // Update minimum status for the modified order using server data
      this._updateMinimumForOrder(orderId, parseFloat(data.order.subtotal), data.meets_minimum)

      // Update submit button states
      this._updateSubmitStates()

      // Restart polling to pick up item verification results
      if (data.item.verification_pending) {
        if (!this._pollingInterval) this._startPolling()
        setTimeout(() => this._pollVerificationStatus(), 1000)
      }
    })
    .catch(err => {
      console.error("Error adding suggestion:", err)
      // Re-enable button on network/server failure
      btn.disabled = false
      btn.classList.remove("opacity-50", "cursor-not-allowed")
    })
  }

  _insertNewItemRow(orderId, item, verificationPending = false) {
    const card = this._cardForOrder(orderId)
    if (!card) {
      console.warn("[_insertNewItemRow] Card not found for orderId:", orderId)
      return
    }

    const name = item.name || ""
    const sku = item.sku || ""
    const verifyIndicator = verificationPending
      ? `<span class="item-verify-spinner inline-flex items-center ml-1" data-item-verify-id="${item.id}" title="Verifying price..."><svg class="animate-spin h-3 w-3 text-blue-500" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path></svg></span>`
      : ''

    // Desktop table row
    const tbody = card.querySelector("table tbody")
    if (tbody) {
      const tr = document.createElement("tr")
      tr.setAttribute("data-order-review-target", "itemRow")
      tr.setAttribute("data-item-id", item.id)
      tr.setAttribute("data-order-id", orderId)
      tr.setAttribute("data-unit-price", item.unit_price)
      tr.setAttribute("data-sku", item.sku)
      tr.innerHTML = `
        <td class="px-4 py-2 text-sm text-gray-900">${this._escapeHtml(name)}</td>
        <td class="px-4 py-2 text-sm text-gray-500">${this._escapeHtml(sku)}</td>
        <td class="px-4 py-2 text-center">
          <div class="inline-flex items-center gap-1">
            <button type="button"
                    data-action="order-review#decrementItem"
                    data-item-id="${item.id}"
                    data-order-id="${orderId}"
                    class="w-7 h-7 flex items-center justify-center rounded-md border border-gray-300 text-gray-600 hover:bg-gray-200 hover:border-gray-400 hover:text-gray-900 active:bg-gray-300 transition-colors text-sm">
              &minus;
            </button>
            <input type="number"
                   value="${item.quantity}"
                   min="1"
                   class="w-14 rounded-md border-gray-300 text-sm text-center [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
                   data-order-review-target="quantityInput"
                   data-action="change->order-review#updateQuantity"
                   data-item-id="${item.id}"
                   data-order-id="${orderId}">
            <button type="button"
                    data-action="order-review#incrementItem"
                    data-item-id="${item.id}"
                    data-order-id="${orderId}"
                    class="w-7 h-7 flex items-center justify-center rounded-md border border-gray-300 text-gray-600 hover:bg-gray-200 hover:border-gray-400 hover:text-gray-900 active:bg-gray-300 transition-colors text-sm">
              +
            </button>
          </div>
        </td>
        <td class="px-4 py-2 text-sm text-right">
          <span class="text-gray-900" data-order-review-target="unitPriceDisplay" data-item-id="${item.id}">${this._formatCurrency(item.unit_price)}${verifyIndicator}</span>
          <span class="hidden block text-xs mt-0.5" data-order-review-target="priceDiff" data-item-id="${item.id}"></span>
        </td>
        <td class="px-4 py-2 text-sm font-medium text-gray-900 text-right" data-order-review-target="lineTotal" data-item-id="${item.id}">
          ${this._formatCurrency(item.line_total)}
        </td>
        <td class="px-4 py-2 text-center">
          <button type="button"
                  data-action="order-review#removeItem"
                  data-item-id="${item.id}"
                  data-order-id="${orderId}"
                  class="text-red-400 hover:text-red-600 transition-colors"
                  title="Remove item">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
            </svg>
          </button>
        </td>
      `
      tr.classList.add("bg-green-50")
      tbody.appendChild(tr)
      setTimeout(() => tr.classList.remove("bg-green-50"), 2000)
    }

    // Mobile card
    const mobileContainer = card.querySelector(".sm\\:hidden")
    if (mobileContainer) {
      const div = document.createElement("div")
      div.className = "p-3 bg-green-50"
      div.setAttribute("data-order-review-target", "itemRow")
      div.setAttribute("data-item-id", item.id)
      div.setAttribute("data-order-id", orderId)
      div.setAttribute("data-unit-price", item.unit_price)
      div.setAttribute("data-sku", item.sku)
      div.innerHTML = `
        <div class="flex justify-between items-start mb-2">
          <div class="flex-1 min-w-0 mr-3">
            <p class="text-sm font-medium text-gray-900">${this._escapeHtml(name)}</p>
            <p class="text-xs text-gray-400">SKU: ${this._escapeHtml(sku)}</p>
          </div>
          <div class="flex items-center gap-2">
            <span class="text-sm font-semibold text-gray-900" data-order-review-target="lineTotal" data-item-id="${item.id}">
              ${this._formatCurrency(item.line_total)}
            </span>
            <button type="button"
                    data-action="order-review#removeItem"
                    data-item-id="${item.id}"
                    data-order-id="${orderId}"
                    class="text-red-400 hover:text-red-600 transition-colors"
                    title="Remove item">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
              </svg>
            </button>
          </div>
        </div>
        <div class="flex items-center justify-between">
          <div>
            <span class="text-xs text-gray-500" data-order-review-target="unitPriceDisplay" data-item-id="${item.id}">${this._formatCurrency(item.unit_price)} each${verificationPending ? verifyIndicator : ''}</span>
            <span class="hidden text-xs" data-order-review-target="priceDiff" data-item-id="${item.id}"></span>
          </div>
          <div class="inline-flex items-center gap-1">
            <button type="button"
                    data-action="order-review#decrementItem"
                    data-item-id="${item.id}"
                    data-order-id="${orderId}"
                    class="w-8 h-8 flex items-center justify-center rounded-md border border-gray-300 text-gray-600 hover:bg-gray-200 hover:border-gray-400 hover:text-gray-900 active:bg-gray-300 transition-colors">
              &minus;
            </button>
            <input type="number"
                   value="${item.quantity}"
                   min="1"
                   class="w-14 rounded-md border-gray-300 text-sm text-center [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
                   data-order-review-target="quantityInput"
                   data-action="change->order-review#updateQuantity"
                   data-item-id="${item.id}"
                   data-order-id="${orderId}">
            <button type="button"
                    data-action="order-review#incrementItem"
                    data-item-id="${item.id}"
                    data-order-id="${orderId}"
                    class="w-8 h-8 flex items-center justify-center rounded-md border border-gray-300 text-gray-600 hover:bg-gray-200 hover:border-gray-400 hover:text-gray-900 active:bg-gray-300 transition-colors">
              +
            </button>
          </div>
        </div>
      `
      mobileContainer.appendChild(div)
      setTimeout(() => div.classList.remove("bg-green-50"), 2000)
    }

    // Timeout: if verification hasn't completed in 30s, stop the spinner
    if (verificationPending) {
      setTimeout(() => {
        const spinner = document.querySelector(`[data-item-verify-id="${item.id}"]`)
        if (spinner && spinner.classList.contains("item-verify-spinner")) {
          spinner.innerHTML = `<svg class="h-3 w-3 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01"/></svg>`
          spinner.classList.remove("item-verify-spinner")
          spinner.title = "Price not yet verified — using last known price"
        }
      }, 30000)
    }
  }

  _updateExistingItemRow(item) {
    const itemId = String(item.id)
    const input = this._inputForItem(itemId)
    if (input) {
      input.value = item.quantity
    }
    this._updateLineTotal(itemId, item.quantity)

    // Flash the row green briefly
    const row = this._rowForItem(itemId)
    if (row) {
      row.classList.add("bg-green-50")
      setTimeout(() => row.classList.remove("bg-green-50"), 2000)
    }
  }

  // Apply server-returned order totals to DOM (more accurate than client recalculation)
  _applyServerTotals(orderId, orderData) {
    if (!orderData) return

    const subtotal = orderData.subtotal
    const itemCount = orderData.item_count

    this.orderSubtotalTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.textContent = this._formatCurrency(subtotal)
      }
    })
    this.orderSubtotalFooterTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.textContent = this._formatCurrency(subtotal)
      }
    })
    this.orderItemCountTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.textContent = itemCount
      }
    })
  }

  // Update minimum status for a single order using server-provided data.
  // This avoids DOM-based recalculation which can be wrong if the browser
  // is serving cached JS or the DOM is out of sync.
  _updateMinimumForOrder(orderId, subtotal, meetsMinimum) {
    const card = this._cardForOrder(orderId)
    if (!card) return

    const minimum = parseFloat(card.dataset.minimum) || 0

    // Update badge
    this.minimumBadgeTargets.forEach(badge => {
      if (badge.dataset.orderId === orderId) {
        if (meetsMinimum) {
          badge.className = "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800"
          badge.textContent = "Ready"
        } else {
          badge.className = "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800"
          badge.textContent = "Minimum not met"
        }
      }
    })

    // Update shortfall text
    this.minimumShortfallTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        if (meetsMinimum) {
          el.style.display = "none"
        } else {
          const shortfall = minimum - subtotal
          el.style.display = "inline"
          el.textContent = `(Need ${this._formatCurrency(shortfall)} more for minimum)`
        }
      }
    })

    // Update card ring
    if (meetsMinimum) {
      card.classList.remove("ring-2", "ring-red-400")
    } else {
      card.classList.add("ring-2", "ring-red-400")
    }

    // Update warning banners
    this.minimumWarningTargets.forEach(warning => {
      if (warning.dataset.orderId === orderId) {
        warning.style.display = meetsMinimum ? "none" : "block"
        if (!meetsMinimum) {
          const supplierName = card.dataset.supplierName
          const shortfall = minimum - subtotal
          const p = warning.querySelector("p")
          if (p) {
            p.innerHTML = `
              <span class="font-medium">Order minimum not met.</span>
              ${supplierName} requires a minimum of
              <strong>${this._formatCurrency(minimum)}</strong> per order.
              <span class="text-red-600">
                Current total: ${this._formatCurrency(subtotal)} &mdash;
                ${this._formatCurrency(shortfall)} more needed.
              </span>
            `
          }
        }
      }
    })

    // Show or hide suggestions based on any minimum status
    const caseMin = parseInt(card.dataset.caseMinimum) || 0
    let totalCases = 0
    if (caseMin > 0) {
      // De-dup by item ID — each item renders twice (desktop tr + mobile div)
      const seen = new Set()
      card.querySelectorAll("[data-order-review-target='itemRow']").forEach(row => {
        if (row.dataset.orderId !== orderId) return
        const itemId = row.dataset.itemId
        if (seen.has(itemId)) return
        seen.add(itemId)
        const input = row.querySelector("[data-order-review-target='quantityInput']")
        totalCases += input ? (parseInt(input.value) || 0) : 0
      })
    }
    const meetsCaseHere = caseMin === 0 || totalCases >= caseMin
    this.suggestionsSectionTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.style.display = (meetsMinimum && meetsCaseHere) ? "none" : ""
      }
    })
  }

  // --- Price verification actions ---

  acceptAllPriceChanges() {
    // User acknowledges price changes — update UI to show they can now submit
    // The price_changed status is already submittable, so just hide the banner
    this._hideAllBanners()

    // Update all price_changed orders to show as "accepted" visually
    this.orderCardTargets.forEach(card => {
      if (card.dataset.verificationStatus === "price_changed") {
        const orderId = card.dataset.orderId
        // Show verified badge instead of price changed
        this.priceChangedBadgeTargets.forEach(el => {
          if (el.dataset.orderId === orderId) {
            el.classList.add("hidden")
            el.classList.remove("inline-flex")
          }
        })
        this.verifiedBadgeTargets.forEach(el => {
          if (el.dataset.orderId === orderId) {
            el.classList.remove("hidden")
            el.classList.add("inline-flex")
            el.textContent = "Price Accepted"
          }
        })
        // Hide per-order price change details
        this.priceChangeDetailsTargets.forEach(el => {
          if (el.dataset.orderId === orderId) el.classList.add("hidden")
        })
      }
    })

    this._updateSubmitStates()
  }

  acceptOrderPriceChanges(event) {
    const orderId = event.currentTarget.dataset.orderId

    // User acknowledges this order's price changes — update UI
    this.priceChangedBadgeTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.classList.add("hidden")
        el.classList.remove("inline-flex")
      }
    })
    this.verifiedBadgeTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.classList.remove("hidden")
        el.classList.add("inline-flex")
        el.textContent = "Price Accepted"
      }
    })
    this.priceChangeDetailsTargets.forEach(el => {
      if (el.dataset.orderId === orderId) el.classList.add("hidden")
    })

    // Check if any price changes remain
    const remainingPriceChanged = this.orderCardTargets.some(card => {
      const cId = card.dataset.orderId
      return cId !== orderId && card.dataset.verificationStatus === "price_changed" &&
        !this.priceChangeDetailsTargets.every(el => el.dataset.orderId !== cId || el.classList.contains("hidden"))
    })
    if (!remainingPriceChanged) {
      this._hideAllBanners()
    }

    this._updateSubmitStates()
  }

  skipAllVerification() {
    const csrfToken = this._csrfToken()
    fetch(`/orders/skip_verification`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "Accept": "application/json"
      },
      body: JSON.stringify({ batch_id: this.batchIdValue })
    })
    .then(res => res.json())
    .then(data => {
      if (data.success) {
        // Update all cards to skipped status and refresh UI
        this._hideAllBanners()
        this._stopPolling()
        this.orderCardTargets.forEach(card => {
          const orderId = card.dataset.orderId
          this._showOrderSkipped(orderId, "Verification skipped by user")
        })
        this._updateSubmitStates()
      }
    })
    .catch(err => console.error("Error skipping verification:", err))
  }

  skipOrderVerification(event) {
    const orderId = event.currentTarget.dataset.orderId
    const csrfToken = this._csrfToken()
    fetch(`/orders/skip_verification`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "Accept": "application/json"
      },
      body: JSON.stringify({ batch_id: this.batchIdValue, order_ids: [orderId] })
    })
    .then(res => res.json())
    .then(data => {
      if (data.success) {
        this._showOrderSkipped(orderId, "Verification skipped by user")
        this._updateSubmitStates()
      }
    })
    .catch(err => console.error("Error skipping verification:", err))
  }

  retryVerification() {
    const csrfToken = this._csrfToken()
    fetch(`/orders/retry_verification`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "Accept": "application/json"
      },
      body: JSON.stringify({ batch_id: this.batchIdValue })
    })
    .then(res => res.json())
    .then(data => {
      if (data.success) {
        this._hideAllBanners()
        this._showVerificationBanner()
        this._startPolling()
      }
    })
    .catch(err => console.error("Error retrying verification:", err))
  }

  retryOrderVerification(event) {
    const orderId = event.currentTarget.dataset.orderId
    const csrfToken = this._csrfToken()
    fetch(`/orders/retry_verification`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken,
        "Accept": "application/json"
      },
      body: JSON.stringify({ batch_id: this.batchIdValue, order_ids: [orderId] })
    })
    .then(res => res.json())
    .then(data => {
      if (data.success) {
        this._hideOrderVerificationUI(orderId)
        this._showOrderVerifying(orderId)
        this._startPolling()
      }
    })
    .catch(err => console.error("Error retrying verification:", err))
  }

  // --- Verification polling ---

  _startPolling() {
    if (this._pollingInterval) return
    this._pollingInterval = setInterval(() => this._pollVerificationStatus(), 2000)
  }

  _stopPolling() {
    if (this._pollingInterval) {
      clearInterval(this._pollingInterval)
      this._pollingInterval = null
    }
  }

  _pollVerificationStatus() {
    fetch(`/orders/verification_status?batch_id=${this.batchIdValue}`, {
      headers: { "Accept": "application/json" }
    })
    .then(res => res.json())
    .then(data => {
      this._updateVerificationUI(data)
      // Keep polling if order-level verification is still running OR individual items are being verified
      const hasUnverifiedItems = data.orders.some(o => o.unverified_items && o.unverified_items.length > 0)
      if (data.summary.all_complete && !hasUnverifiedItems) {
        this._stopPolling()
      }
    })
    .catch(err => {
      console.error("Polling error:", err)
    })
  }

  _updateVerificationUI(data) {
    const { orders, summary } = data

    let anyVerifying = false
    let anyPriceChanged = false
    let anyFailed = false

    orders.forEach(order => {
      const orderId = String(order.id)

      // If order moved to processing/submitted (user already clicked submit), remove the card
      if (order.status === "processing" || order.status === "submitted") {
        const card = this._cardForOrder(orderId)
        if (card) card.remove()
        this._recalculateSummary()
        return
      }

      switch (order.verification_status) {
        case "verifying":
          anyVerifying = true
          this._showOrderVerifying(orderId)
          break
        case "verified":
          this._showOrderVerified(orderId)
          break
        case "price_changed":
          anyPriceChanged = true
          this._showOrderPriceChanged(orderId, order)
          break
        case "failed":
          anyFailed = true
          this._showOrderVerificationFailed(orderId, order.verification_error)
          break
        case "skipped":
          this._showOrderSkipped(orderId, order.verification_error) // show skip reason
          break
      }

      // Update delivery address if received from supplier
      if (order.supplier_delivery_address) {
        this._updateDeliveryAddress(orderId, order.supplier_delivery_address)
      }

      // Mark out-of-stock items (from verification)
      if (order.unavailable_items && order.unavailable_items.length > 0) {
        this._markUnavailableItems(orderId, order.unavailable_items)
      } else {
        // Clear unavailable banner + data-in-stock flags if no items are out of stock
        this._clearUnavailableState(orderId)
      }

      // Per-item verification: swap spinners for checkmarks or price changes
      if (order.newly_verified_items) {
        order.newly_verified_items.forEach(item => {
          this._markItemVerified(item.id)
        })
      }
      if (order.items_with_changes) {
        order.items_with_changes.forEach(item => {
          this._markItemPriceChanged(item)
        })
      }
    })

    // Update top-level banners
    this._hideAllBanners()
    if (anyVerifying) {
      this._showVerificationBanner()
      const verifiedCount = summary.verified + summary.price_changed
      if (this.hasVerificationProgressTarget) {
        this.verificationProgressTarget.textContent =
          `${verifiedCount} of ${summary.total_orders} verified...`
      }
    } else if (anyPriceChanged) {
      this._showPriceChangeBanner()
    } else if (anyFailed) {
      this._showVerificationFailedBanner()
    }
    // else: all verified — banners hidden, submit buttons enabled

    // Show "Saved as draft" notification when verification completes
    if (summary.saved_as_draft && !this._draftNotificationShown) {
      this._draftNotificationShown = true
      if (this.hasDraftBannerTarget) {
        this.draftBannerTarget.classList.remove("hidden")
        setTimeout(() => {
          this.draftBannerTarget.classList.add("hidden")
        }, 8000)
      }
    }

    // If no more orders on page (all submitted), redirect
    if (this.orderCardTargets.length === 0) {
      window.location.href = "/orders"
    }

    // Update submit button states based on verification results
    this._updateSubmitStates()
  }

  // --- Per-item verification UI updates ---

  _markItemVerified(itemId) {
    const spinner = document.querySelector(`[data-item-verify-id="${itemId}"]`)
    if (spinner) {
      spinner.innerHTML = `<svg class="h-3 w-3 text-green-500" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M5 13l4 4L19 7"/></svg>`
      spinner.classList.remove("item-verify-spinner")
      spinner.title = "Price verified"
      // Fade out checkmark after 3 seconds
      setTimeout(() => { if (spinner.parentNode) spinner.remove() }, 3000)
    }
  }

  _markItemPriceChanged(item) {
    const itemId = String(item.id)

    // First remove any spinner
    const spinner = document.querySelector(`[data-item-verify-id="${itemId}"]`)
    if (spinner) spinner.remove()

    // Update the unit price display with the new price and diff
    const direction = item.difference > 0 ? "+" : ""
    const color = item.difference > 0 ? "text-red-600" : "text-green-600"
    this.unitPriceDisplayTargets.forEach(el => {
      if (el.dataset.itemId === itemId) {
        el.innerHTML = `${this._formatCurrency(item.verified_price)} <span class="${color} text-xs">(${direction}${this._formatCurrency(item.difference)})</span>`
      }
    })

    // Update data-unit-price on ALL rows (desktop + mobile) and recalculate
    let qty = 1
    this.itemRowTargets.forEach(row => {
      if (row.dataset.itemId === itemId) {
        row.setAttribute("data-unit-price", item.verified_price)
        const input = row.querySelector('[data-order-review-target="quantityInput"]')
        if (input) qty = parseInt(input.value) || 1
      }
    })
    this._updateLineTotal(itemId, qty)
    this._scheduleRecalculation()
  }

  // --- Per-order verification UI updates ---

  _showOrderVerifying(orderId) {
    this._hideOrderVerificationUI(orderId)
    this._setVerificationStatus(orderId, "verifying")
    this.verifyingIndicatorTargets.forEach(el => {
      if (el.dataset.orderId === orderId) el.classList.remove("hidden")
    })
  }

  _updateDeliveryAddress(orderId, address) {
    this.deliveryAddressTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.innerHTML = `<span class="text-gray-900 text-sm">${this._escapeHtml(address)}</span>`
      }
    })
  }

  _markUnavailableItems(orderId, unavailableItems) {
    const itemIds = unavailableItems.map(i => String(i.id))

    this.itemRowTargets.forEach(row => {
      if (row.offsetParent === null) return // skip hidden (mobile/desktop dual render)
      const itemId = row.dataset.itemId
      if (!itemIds.includes(itemId)) return

      // Mark row with red background
      row.classList.add("bg-red-50")
      row.dataset.inStock = "false"

      // Add "Out of stock" badge if not already present
      const existingBadge = row.querySelector("[data-order-review-target='stockBadge']")
      if (!existingBadge) {
        const nameCell = row.querySelector("td, .flex-1")
        if (nameCell) {
          const badge = document.createElement("span")
          badge.className = "inline-flex items-center ml-2 px-1.5 py-0.5 rounded text-xs font-medium bg-red-100 text-red-700"
          badge.dataset.orderReviewTarget = "stockBadge"
          badge.dataset.itemId = itemId
          badge.textContent = "Out of stock"
          const nameEl = nameCell.querySelector("p, span") || nameCell
          nameEl.appendChild(badge)
        }
      }
    })

    // Show warning banner for this order
    if (unavailableItems.length > 0) {
      const card = this._cardForOrder(orderId)
      if (card && !card.querySelector(".unavailable-banner")) {
        const itemsTable = card.querySelector("table, .divide-y")
        if (itemsTable) {
          const banner = document.createElement("div")
          banner.className = "unavailable-banner mx-4 mb-3 p-3 bg-red-50 border border-red-200 rounded-lg text-sm text-red-700"
          const names = unavailableItems.map(i => i.name).join(", ")
          banner.innerHTML = `
            <div class="flex items-start gap-2">
              <svg class="w-4 h-4 mt-0.5 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.28 7.22a.75.75 0 00-1.06 1.06L8.94 10l-1.72 1.72a.75.75 0 101.06 1.06L10 11.06l1.72 1.72a.75.75 0 101.06-1.06L11.06 10l1.72-1.72a.75.75 0 00-1.06-1.06L10 8.94 8.28 7.22z" clip-rule="evenodd"/></svg>
              <div><strong>${unavailableItems.length} item${unavailableItems.length > 1 ? 's' : ''} out of stock:</strong> ${this._escapeHtml(names)}. Remove ${unavailableItems.length > 1 ? 'them' : 'it'} to submit this order.</div>
            </div>
          `
          itemsTable.parentNode.insertBefore(banner, itemsTable)
        }
      }
    }

    this._updateSubmitStates()
  }

  _clearUnavailableState(orderId) {
    const card = this._cardForOrder(orderId)
    if (!card) return

    // Remove the unavailable banner
    const banner = card.querySelector(".unavailable-banner")
    if (banner) banner.remove()

    // Clear any data-in-stock="false" flags on remaining rows
    card.querySelectorAll("[data-in-stock='false']").forEach(el => {
      el.dataset.inStock = "true"
      el.classList.remove("bg-red-50")
      const badge = el.querySelector("[data-order-review-target='stockBadge']")
      if (badge) badge.remove()
    })
  }

  _showOrderVerified(orderId) {
    this._hideOrderVerificationUI(orderId)
    this._setVerificationStatus(orderId, "verified")
    this.verifiedBadgeTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.classList.remove("hidden")
        el.classList.add("inline-flex")
      }
    })
  }

  _showOrderSkipped(orderId, reason) {
    this._hideOrderVerificationUI(orderId)
    this._setVerificationStatus(orderId, "skipped")
    // Show the verified badge but with "Skipped" styling and reason tooltip
    this.verifiedBadgeTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.classList.remove("hidden", "bg-green-100", "text-green-800")
        el.classList.add("inline-flex", "bg-yellow-100", "text-yellow-800")
        el.innerHTML = `
          <svg class="w-3 h-3 mr-1" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd"/></svg>
          Using Saved Prices
        `
        if (reason) el.title = reason
      }
    })
  }

  _showOrderPriceChanged(orderId, orderData) {
    this._hideOrderVerificationUI(orderId)
    this._setVerificationStatus(orderId, "price_changed")
    this.priceChangedBadgeTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.classList.remove("hidden")
        el.classList.add("inline-flex")
      }
    })

    // Show price change details section
    this.priceChangeDetailsTargets.forEach(el => {
      if (el.dataset.orderId === orderId) el.classList.remove("hidden")
    })

    // Populate price change list
    if (orderData.items_with_changes && orderData.items_with_changes.length > 0) {
      this.priceChangeListTargets.forEach(el => {
        if (el.dataset.orderId === orderId) {
          el.innerHTML = orderData.items_with_changes.map(item => {
            const sign = item.difference > 0 ? "+" : ""
            const color = item.difference > 0 ? "text-red-600" : "text-green-600"
            return `
              <div class="flex items-center justify-between text-xs">
                <span class="text-gray-700">${item.name} (${item.sku})</span>
                <span>
                  <span class="text-gray-500 line-through">${this._formatCurrency(item.expected_price)}</span>
                  <span class="font-medium ml-1">${this._formatCurrency(item.verified_price)}</span>
                  <span class="${color} ml-1">(${sign}${this._formatCurrency(item.difference)})</span>
                </span>
              </div>
            `
          }).join("")
        }
      })

      // Update inline price diffs on item rows
      orderData.items_with_changes.forEach(item => {
        const itemId = String(item.id)
        this.priceDiffTargets.forEach(el => {
          if (el.dataset.itemId === itemId) {
            const sign = item.difference > 0 ? "+" : ""
            const color = item.difference > 0 ? "text-red-600" : "text-green-600"
            el.classList.remove("hidden")
            el.className = el.className.replace(/text-\w+-\d+/g, "")
            el.classList.add(color, "text-xs")
            el.textContent = `${sign}${this._formatCurrency(item.difference)} (now ${this._formatCurrency(item.verified_price)})`
          }
        })
      })
    }
  }

  _showOrderVerificationFailed(orderId, errorMessage) {
    this._hideOrderVerificationUI(orderId)
    this._setVerificationStatus(orderId, "failed")
    this.verifyFailedBadgeTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.classList.remove("hidden")
        el.classList.add("inline-flex")
      }
    })
    // Show error details
    this.verificationErrorDetailsTargets.forEach(el => {
      if (el.dataset.orderId === orderId) el.classList.remove("hidden")
    })
    this.verificationErrorTextTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.textContent = errorMessage || "Verification failed. You can retry or skip."
      }
    })
  }

  _hideOrderVerificationUI(orderId) {
    // Hide all verification indicators for this order
    this.verifyingIndicatorTargets.forEach(el => {
      if (el.dataset.orderId === orderId) el.classList.add("hidden")
    })
    this.verifiedBadgeTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.classList.add("hidden")
        el.classList.remove("inline-flex")
      }
    })
    this.priceChangedBadgeTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.classList.add("hidden")
        el.classList.remove("inline-flex")
      }
    })
    this.verifyFailedBadgeTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.classList.add("hidden")
        el.classList.remove("inline-flex")
      }
    })
    this.priceChangeDetailsTargets.forEach(el => {
      if (el.dataset.orderId === orderId) el.classList.add("hidden")
    })
    this.verificationErrorDetailsTargets.forEach(el => {
      if (el.dataset.orderId === orderId) el.classList.add("hidden")
    })
  }

  // --- Top-level banner management ---

  _showVerificationBanner() {
    if (this.hasVerificationBannerTarget) {
      this.verificationBannerTarget.classList.remove("hidden")
    }
    this._setVerifyingLock(true)
  }

  _showPriceChangeBanner() {
    if (this.hasPriceChangeBannerTarget) {
      this.priceChangeBannerTarget.classList.remove("hidden")
    }
  }

  _showVerificationFailedBanner() {
    if (this.hasVerificationFailedBannerTarget) {
      this.verificationFailedBannerTarget.classList.remove("hidden")
    }
  }

  _hideAllBanners() {
    if (this.hasVerificationBannerTarget) {
      this.verificationBannerTarget.classList.add("hidden")
    }
    if (this.hasPriceChangeBannerTarget) {
      this.priceChangeBannerTarget.classList.add("hidden")
    }
    if (this.hasVerificationFailedBannerTarget) {
      this.verificationFailedBannerTarget.classList.add("hidden")
    }
    this._setVerifyingLock(false)
  }

  // Lock/unlock all interactive controls during verification to prevent impatient clicks
  _setVerifyingLock(locked) {
    this._verifyingLocked = locked
    const selector = [
      'button[data-action*="incrementItem"]',
      'button[data-action*="decrementItem"]',
      'button[data-action*="removeItem"]',
      'button[data-action*="addSuggestion"]',
      'button[data-action*="openForgotSomething"]',
      'input[data-order-review-target="quantityInput"]',
      'input[data-order-review-target="deliveryDate"]'
    ].join(", ")

    this.element.querySelectorAll(selector).forEach(el => {
      el.disabled = locked
      if (locked) {
        el.classList.add("opacity-50", "cursor-not-allowed")
      } else {
        el.classList.remove("opacity-50", "cursor-not-allowed")
      }
    })
  }

  // --- Recalculation helpers ---

  // Coalesce multiple rapid clicks into a single recalculation in the next frame.
  // This lets the browser paint input/line-total changes immediately.
  _scheduleRecalculation() {
    if (this._recalcRAF) cancelAnimationFrame(this._recalcRAF)
    this._recalcRAF = requestAnimationFrame(() => {
      this._recalcRAF = null
      this._recalculateAll()
    })
  }

  // Single-pass recalculation that replaces the previous pattern of calling
  // _recalculateOrderTotals + _recalculateSummary + _updateMinimumStatus
  // + _updateSubmitStates in sequence. Those four functions each independently
  // looped through all item rows checking offsetParent (forces layout reflow).
  // With ~500 items (1000 rows for desktop+mobile), that caused massive
  // layout thrashing: 4 passes × 1000 offsetParent reads with DOM writes
  // between passes.
  //
  // This version reads ALL layout data in one pass (single reflow), then
  // does all DOM writes without interleaved reads.
  _recalculateAll() {
    // ── Phase 1: READ — collect all row data in a single pass ──
    // Reading offsetParent only once per row (without intervening writes)
    // triggers a single layout computation instead of thousands.
    const cardData = []
    let totalItems = 0
    let totalAmount = 0

    this.orderCardTargets.forEach(card => {
      const orderId = card.dataset.orderId
      const minimum = parseFloat(card.dataset.minimum) || 0
      const caseMin = parseInt(card.dataset.caseMinimum) || 0

      const rows = card.querySelectorAll("[data-order-review-target='itemRow']")
      let subtotal = 0
      let itemCount = 0
      let totalCases = 0

      for (let i = 0; i < rows.length; i++) {
        const row = rows[i]
        // offsetParent is the only layout-forcing read — done in a batch
        if (row.offsetParent === null) continue

        const unitPrice = parseFloat(row.dataset.unitPrice) || 0
        const input = row.querySelector("[data-order-review-target='quantityInput']")
        const qty = input ? (parseInt(input.value) || 0) : 0
        subtotal += unitPrice * qty
        totalCases += qty
        itemCount++
      }

      totalItems += itemCount
      totalAmount += subtotal

      const meetsMinium = minimum === 0 || subtotal >= minimum
      const meetsCaseMin = caseMin === 0 || totalCases >= caseMin
      const hasDate = this._hasValidDeliveryDate(orderId)
      const verificationStatus = card.dataset.verificationStatus
      const isVerified = ["verified", "price_changed", "skipped"].includes(verificationStatus)
      const hasNoUnavailable = !card.querySelector("[data-in-stock='false']")
      const hasCredentials = card.dataset.hasCredentials !== "false"
      const canSubmit = hasCredentials && meetsMinium && meetsCaseMin && hasDate && isVerified && hasNoUnavailable

      cardData.push({
        orderId, card, subtotal, itemCount, totalCases,
        minimum, caseMin, meetsMinium, meetsCaseMin, canSubmit
      })
    })

    // ── Phase 2: WRITE — all DOM mutations, no layout reads ──
    let allCanSubmit = true

    for (let c = 0; c < cardData.length; c++) {
      const { orderId, card, subtotal, itemCount, totalCases,
              minimum, caseMin, meetsMinium, canSubmit } = cardData[c]

      if (!canSubmit) allCanSubmit = false

      // Order subtotals
      this.orderSubtotalTargets.forEach(el => {
        if (el.dataset.orderId === orderId) el.textContent = this._formatCurrency(subtotal)
      })
      this.orderSubtotalFooterTargets.forEach(el => {
        if (el.dataset.orderId === orderId) el.textContent = this._formatCurrency(subtotal)
      })
      this.orderItemCountTargets.forEach(el => {
        if (el.dataset.orderId === orderId) el.textContent = itemCount
      })

      // Minimum badge
      this.minimumBadgeTargets.forEach(badge => {
        if (badge.dataset.orderId === orderId) {
          if (meetsMinium) {
            badge.className = "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800"
            badge.textContent = "Ready"
          } else {
            badge.className = "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800"
            badge.textContent = "Minimum not met"
          }
        }
      })

      // Shortfall text
      this.minimumShortfallTargets.forEach(el => {
        if (el.dataset.orderId === orderId) {
          if (meetsMinium) {
            el.style.display = "none"
          } else {
            const shortfall = minimum - subtotal
            el.style.display = "inline"
            el.textContent = `(Need ${this._formatCurrency(shortfall)} more for minimum)`
          }
        }
      })

      // Card ring
      if (meetsMinium) {
        card.classList.remove("ring-2", "ring-red-400")
      } else {
        card.classList.add("ring-2", "ring-red-400")
      }

      // Warning banners
      this.minimumWarningTargets.forEach(warning => {
        if (warning.dataset.orderId === orderId) {
          warning.style.display = meetsMinium ? "none" : "block"
          if (!meetsMinium) {
            const supplierName = card.dataset.supplierName
            const shortfall = minimum - subtotal
            const p = warning.querySelector("p")
            if (p) {
              p.innerHTML = `
                <span class="font-medium">Order minimum not met.</span>
                ${supplierName} requires a minimum of
                <strong>${this._formatCurrency(minimum)}</strong> per order.
                <span class="text-red-600">
                  Current total: ${this._formatCurrency(subtotal)} &mdash;
                  ${this._formatCurrency(shortfall)} more needed.
                </span>
              `
            }
          }
        }
      })

      // Case minimum
      const meetsCaseMin = caseMin === 0 || totalCases >= caseMin

      // Suggestions (show when any minimum not met)
      this.suggestionsSectionTargets.forEach(el => {
        if (el.dataset.orderId === orderId) {
          el.style.display = (meetsMinium && meetsCaseMin) ? "none" : ""
        }
      })

      if (caseMin > 0) {

        this.caseMinimumWarningTargets.forEach(warning => {
          if (warning.dataset.orderId === orderId) {
            warning.style.display = meetsCaseMin ? "none" : "block"
            if (!meetsCaseMin) {
              const shortfallEl = warning.querySelector("[data-order-review-target='caseMinimumShortfall']")
              if (shortfallEl) {
                const diff = caseMin - totalCases
                shortfallEl.textContent =
                  `You currently have ${totalCases} case${totalCases === 1 ? '' : 's'} — ${diff} more needed.`
              }
            }
          }
        })

        this.caseMinimumBadgeTargets.forEach(badge => {
          if (badge.dataset.orderId === orderId) {
            if (meetsCaseMin) {
              badge.style.display = "none"
            } else {
              badge.style.display = ""
              const diff = caseMin - totalCases
              badge.textContent = `${diff} more case${diff === 1 ? '' : 's'} needed`
            }
          }
        })
      }

      // Per-supplier submit button
      // button_to puts data- on the <form>, so target the <button> inside
      this.supplierSubmitBtnTargets.forEach(form => {
        if (form.dataset.orderId === orderId) {
          const btn = form.querySelector("button[type='submit'], input[type='submit']") || form
          if (canSubmit) {
            btn.disabled = false
            btn.classList.remove("bg-gray-300", "bg-gray-600", "opacity-50", "text-gray-400", "cursor-not-allowed")
            btn.classList.add("bg-brand-orange", "hover:bg-brand-orange-dark", "text-white", "cursor-pointer")
          } else {
            btn.disabled = true
            btn.classList.add("bg-gray-600", "opacity-50", "text-gray-400", "cursor-not-allowed")
            btn.classList.remove("bg-brand-orange", "hover:bg-brand-orange-dark", "text-white", "cursor-pointer")
          }
        }
      })
    }

    // Summary bar
    if (this.hasSummaryOrdersTarget) this.summaryOrdersTarget.textContent = cardData.length
    if (this.hasSummaryItemsTarget) this.summaryItemsTarget.textContent = totalItems
    if (this.hasSummaryTotalTarget) this.summaryTotalTarget.textContent = this._formatCurrency(totalAmount)

    // Submit All button
    // button_to puts data- on the <form>, so target the <button> inside
    this.submitAllBtnTargets.forEach(form => {
      const btn = form.querySelector("button[type='submit'], input[type='submit']") || form
      if (allCanSubmit && cardData.length > 0) {
        btn.disabled = false
        btn.classList.remove("bg-gray-300", "bg-gray-600", "opacity-50", "text-gray-400", "cursor-not-allowed")
        btn.classList.add("bg-brand-orange", "hover:bg-brand-orange-dark", "text-white", "cursor-pointer")
      } else {
        btn.disabled = true
        btn.classList.add("bg-gray-600", "opacity-50", "text-gray-400", "cursor-not-allowed")
        btn.classList.remove("bg-brand-orange", "hover:bg-brand-orange-dark", "text-white", "cursor-pointer")
      }
    })
  }

  _recalculateOrderTotals(orderId) {
    const card = this._cardForOrder(orderId)
    if (!card) return

    // Filter to visible rows only — page has both desktop (table) and mobile (card) markup
    const rows = Array.from(card.querySelectorAll("[data-order-review-target='itemRow']"))
      .filter(row => row.offsetParent !== null)
    let subtotal = 0
    let itemCount = 0

    rows.forEach(row => {
      const unitPrice = parseFloat(row.dataset.unitPrice) || 0
      const input = row.querySelector("[data-order-review-target='quantityInput']")
      const qty = input ? (parseInt(input.value) || 0) : 0
      subtotal += unitPrice * qty
      itemCount++
    })

    // Update order subtotal displays
    this.orderSubtotalTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.textContent = this._formatCurrency(subtotal)
      }
    })
    this.orderSubtotalFooterTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.textContent = this._formatCurrency(subtotal)
      }
    })
    this.orderItemCountTargets.forEach(el => {
      if (el.dataset.orderId === orderId) {
        el.textContent = itemCount
      }
    })
  }

  _recalculateSummary() {
    const cards = this.orderCardTargets
    let orderCount = cards.length
    let totalItems = 0
    let totalAmount = 0

    cards.forEach(card => {
      // Filter to visible rows only — avoid double-counting desktop + mobile markup
      const rows = Array.from(card.querySelectorAll("[data-order-review-target='itemRow']"))
        .filter(row => row.offsetParent !== null)
      rows.forEach(row => {
        const unitPrice = parseFloat(row.dataset.unitPrice) || 0
        const input = row.querySelector("[data-order-review-target='quantityInput']")
        const qty = input ? (parseInt(input.value) || 0) : 0
        totalAmount += unitPrice * qty
        totalItems++
      })
    })

    if (this.hasSummaryOrdersTarget) this.summaryOrdersTarget.textContent = orderCount
    if (this.hasSummaryItemsTarget) this.summaryItemsTarget.textContent = totalItems
    if (this.hasSummaryTotalTarget) this.summaryTotalTarget.textContent = this._formatCurrency(totalAmount)
  }

  _updateMinimumStatus() {
    let allMet = true

    this.orderCardTargets.forEach(card => {
      const orderId = card.dataset.orderId
      const minimum = parseFloat(card.dataset.minimum) || 0

      // Calculate current subtotal for this card (visible rows only)
      const rows = Array.from(card.querySelectorAll("[data-order-review-target='itemRow']"))
        .filter(row => row.offsetParent !== null)
      let subtotal = 0
      rows.forEach(row => {
        const unitPrice = parseFloat(row.dataset.unitPrice) || 0
        const input = row.querySelector("[data-order-review-target='quantityInput']")
        const qty = input ? (parseInt(input.value) || 0) : 0
        subtotal += unitPrice * qty
      })

      const meetsMinium = minimum === 0 || subtotal >= minimum

      if (!meetsMinium) allMet = false

      // Update badge
      this.minimumBadgeTargets.forEach(badge => {
        if (badge.dataset.orderId === orderId) {
          if (meetsMinium) {
            badge.className = "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800"
            badge.textContent = "Ready"
          } else {
            badge.className = "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-yellow-100 text-yellow-800"
            badge.textContent = "Minimum not met"
          }
        }
      })

      // Update shortfall text
      this.minimumShortfallTargets.forEach(el => {
        if (el.dataset.orderId === orderId) {
          if (meetsMinium) {
            el.style.display = "none"
          } else {
            const shortfall = minimum - subtotal
            el.style.display = "inline"
            el.textContent = `(Need ${this._formatCurrency(shortfall)} more for minimum)`
          }
        }
      })

      // Update card ring
      if (meetsMinium) {
        card.classList.remove("ring-2", "ring-red-400")
      } else {
        card.classList.add("ring-2", "ring-red-400")
      }

      // Update warning banners
      this.minimumWarningTargets.forEach(warning => {
        if (warning.dataset.orderId === orderId) {
          warning.style.display = meetsMinium ? "none" : "block"
          if (!meetsMinium) {
            const supplierName = card.dataset.supplierName
            const shortfall = minimum - subtotal
            const p = warning.querySelector("p")
            if (p) {
              p.innerHTML = `
                <span class="font-medium">Order minimum not met.</span>
                ${supplierName} requires a minimum of
                <strong>${this._formatCurrency(minimum)}</strong> per order.
                <span class="text-red-600">
                  Current total: ${this._formatCurrency(subtotal)} &mdash;
                  ${this._formatCurrency(shortfall)} more needed.
                </span>
              `
            }
          }
        }
      })

      // Case minimum (blocking)
      const caseMin = parseInt(card.dataset.caseMinimum) || 0
      let totalCasesForMin = 0
      rows.forEach(row => {
        const input = row.querySelector("[data-order-review-target='quantityInput']")
        totalCasesForMin += input ? (parseInt(input.value) || 0) : 0
      })
      const meetsCaseMinHere = caseMin === 0 || totalCasesForMin >= caseMin

      // Show or hide suggestions based on any minimum status
      this.suggestionsSectionTargets.forEach(el => {
        if (el.dataset.orderId === orderId) {
          el.style.display = (meetsMinium && meetsCaseMinHere) ? "none" : ""
        }
      })

      if (caseMin > 0) {
        const meetsCaseMin = totalCasesForMin >= caseMin

        this.caseMinimumWarningTargets.forEach(warning => {
          if (warning.dataset.orderId === orderId) {
            warning.style.display = meetsCaseMin ? "none" : "block"
            if (!meetsCaseMin) {
              const shortfallEl = warning.querySelector("[data-order-review-target='caseMinimumShortfall']")
              if (shortfallEl) {
                const diff = caseMin - totalCasesForMin
                shortfallEl.textContent =
                  `You currently have ${totalCasesForMin} case${totalCasesForMin === 1 ? '' : 's'} — ${diff} more needed.`
              }
            }
          }
        })

        this.caseMinimumBadgeTargets.forEach(badge => {
          if (badge.dataset.orderId === orderId) {
            if (meetsCaseMin) {
              badge.style.display = "none"
            } else {
              badge.style.display = ""
              const diff = caseMin - totalCasesForMin
              badge.textContent = `${diff} more case${diff === 1 ? '' : 's'} needed`
            }
          }
        })
      }
    })

    this._updateSubmitStates()
  }

  _clearDeliveryDateWarning(orderId, input) {
    if (!input.value) return

    // Remove warning text
    const warning = this.deliveryDateWarningTargets.find(el => el.dataset.orderId === orderId)
    if (warning) warning.remove()

    // Remove required asterisk
    const required = this.deliveryDateRequiredTargets.find(el => el.dataset.orderId === orderId)
    if (required) required.remove()

    // Fix label color: amber → gray
    const label = this.deliveryDateLabelTargets.find(el => el.dataset.orderId === orderId)
    if (label) {
      label.classList.remove("text-amber-700")
      label.classList.add("text-gray-500")
    }

    // Fix row background: amber → gray
    const row = this.deliveryRowTargets.find(el => el.dataset.orderId === orderId)
    if (row) {
      row.classList.remove("bg-amber-50", "border-amber-200")
      row.classList.add("bg-gray-50")
    }

    // Fix input border: amber → gray
    input.classList.remove("border-amber-400", "ring-1", "ring-amber-300")
    input.classList.add("border-gray-300")
  }

  _hasValidDeliveryDate(orderId) {
    const dateInput = this.deliveryDateTargets.find(el => el.dataset.orderId === orderId)
    if (!dateInput || !dateInput.value) return false
    const selected = new Date(dateInput.value + "T00:00:00")
    const today = new Date()
    today.setHours(0, 0, 0, 0)
    return selected > today
  }

  _initDeliveryHints() {
    this.deliveryDateTargets.forEach(input => {
      this._updateDeliveryHint(input.dataset.orderId, input.value || null)
    })
  }

  _updateDeliveryHint(orderId, dateVal) {
    const hint = this.deliveryHintTargets.find(el => el.dataset.orderId === orderId)
    if (!hint) return

    const info = (this.deliveryInfoValue || {})[orderId]
    if (!info) { hint.classList.add("hidden"); return }

    const dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    if (!dateVal) {
      if (info.type === "api" && info.dates?.length) {
        hint.textContent = `Available: ${info.dates.slice(0, 3).map(d => this._shortDate(d)).join(", ")}...`
        hint.className = "mt-1 text-xs text-gray-500"
      } else if (info.type === "schedule") {
        hint.textContent = `Delivers ${info.days.map(d => d.day_name.substring(0, 3)).join("/")}`
        hint.className = "mt-1 text-xs text-gray-500"
      }
      return
    }

    if (info.type === "api") {
      if (info.dates.includes(dateVal)) {
        hint.textContent = "\u2713 Valid delivery date"
        hint.className = "mt-1 text-xs text-green-600"
      } else {
        const next = info.dates.find(d => d > dateVal)
        hint.textContent = next
          ? `\u26A0 Not a delivery date \u2014 try ${this._shortDate(next)}`
          : "\u26A0 No delivery dates available"
        hint.className = "mt-1 text-xs text-amber-600"
      }
    } else if (info.type === "schedule") {
      const selected = new Date(dateVal + "T00:00:00")
      const validDays = info.days.map(d => d.day)
      if (validDays.includes(selected.getDay())) {
        const sched = info.days.find(d => d.day === selected.getDay())
        const cutoff = sched ? ` \u00B7 order by ${sched.cutoff_day_name.substring(0, 3)} ${this._fmtTime(sched.cutoff_time)}` : ""
        hint.textContent = `\u2713 Valid delivery date${cutoff}`
        hint.className = "mt-1 text-xs text-green-600"
      } else {
        const days = info.days.map(d => d.day_name.substring(0, 3)).join("/")
        hint.textContent = `\u26A0 Delivers ${days} only`
        hint.className = "mt-1 text-xs text-amber-600"
      }
    }
  }

  _shortDate(iso) {
    return new Date(iso + "T00:00:00").toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" })
  }

  _fmtTime(timeStr) {
    const [h, m] = timeStr.split(":").map(Number)
    const ampm = h >= 12 ? "pm" : "am"
    const h12 = h % 12 || 12
    return m === 0 ? `${h12}${ampm}` : `${h12}:${m.toString().padStart(2, "0")}${ampm}`
  }

  _updateSubmitStates() {
    let submittableCount = 0
    const totalCount = this.orderCardTargets.length

    this.orderCardTargets.forEach(card => {
      const orderId = card.dataset.orderId
      const minimum = parseFloat(card.dataset.minimum) || 0
      const caseMin = parseInt(card.dataset.caseMinimum) || 0
      const verificationStatus = card.dataset.verificationStatus

      // Calculate subtotal and case count.
      // Each item is rendered twice (desktop table row + mobile card), both with
      // data-order-review-target="itemRow" — de-dup by data-item-id to avoid
      // doubling the subtotal and falsely clearing the minimum check.
      const rows = card.querySelectorAll("[data-order-review-target='itemRow']")
      const seenItemIds = new Set()
      let subtotal = 0
      let totalCases = 0
      rows.forEach(row => {
        const itemId = row.dataset.itemId
        if (seenItemIds.has(itemId)) return
        seenItemIds.add(itemId)
        const unitPrice = parseFloat(row.dataset.unitPrice) || 0
        const input = row.querySelector("[data-order-review-target='quantityInput']")
        const qty = input ? (parseInt(input.value) || 0) : 0
        subtotal += unitPrice * qty
        totalCases += qty
      })

      const meetsMinimum = minimum === 0 || subtotal >= minimum
      const meetsCaseMin = caseMin === 0 || totalCases >= caseMin
      const hasDate = this._hasValidDeliveryDate(orderId)
      const isVerified = ["verified", "price_changed", "skipped"].includes(verificationStatus)
      const hasNoUnavailable = !card.querySelector("[data-in-stock='false']")
      const hasCredentials = card.dataset.hasCredentials !== "false"
      const canSubmit = hasCredentials && meetsMinimum && meetsCaseMin && hasDate && isVerified && hasNoUnavailable

      if (canSubmit) submittableCount++

      // Update per-supplier submit button
      // button_to puts data- on the <form>, so target the <button> inside
      this.supplierSubmitBtnTargets.forEach(form => {
        if (form.dataset.orderId === orderId) {
          const btn = form.querySelector("button[type='submit'], input[type='submit']") || form
          if (canSubmit) {
            btn.disabled = false
            btn.classList.remove("bg-gray-300", "bg-gray-600", "opacity-50", "text-gray-400", "cursor-not-allowed")
            btn.classList.add("bg-brand-orange", "hover:bg-brand-orange-dark", "text-white", "cursor-pointer")
          } else {
            btn.disabled = true
            btn.classList.add("bg-gray-600", "opacity-50", "text-gray-400", "cursor-not-allowed")
            btn.classList.remove("bg-brand-orange", "hover:bg-brand-orange-dark", "text-white", "cursor-pointer")
          }
        }
      })
    })

    // Update "Submit All" button text and state
    // button_to puts data- on the <form>, so target the <button> inside
    this.submitAllBtnTargets.forEach(form => {
      const btn = form.querySelector("button[type='submit'], input[type='submit']") || form
      const label = submittableCount === totalCount
        ? "Submit All Orders"
        : `Submit ${submittableCount} of ${totalCount} Orders`
      if (btn.value !== undefined && btn.type === "submit") {
        btn.value = label
      } else {
        btn.textContent = label
      }

      if (submittableCount > 0 && totalCount > 0) {
        btn.disabled = false
        btn.classList.remove("bg-gray-300", "bg-gray-600", "opacity-50", "text-gray-400", "cursor-not-allowed")
        btn.classList.add("bg-brand-orange", "hover:bg-brand-orange-dark", "text-white", "cursor-pointer")
      } else {
        btn.disabled = true
        btn.classList.add("bg-gray-600", "opacity-50", "text-gray-400", "cursor-not-allowed")
        btn.classList.remove("bg-brand-orange", "hover:bg-brand-orange-dark", "text-white", "cursor-pointer")
      }
    })
  }

  _checkIfAllDone() {
    // If no more order cards, redirect to order history
    if (this.orderCardTargets.length === 0) {
      window.location.href = "/orders"
    }
  }

  // --- Server communication ---

  _debouncePatch(itemId, orderId, quantity) {
    const key = `item_${itemId}`
    if (this._debounceTimers[key]) clearTimeout(this._debounceTimers[key])

    this._debounceTimers[key] = setTimeout(() => {
      const csrfToken = this._csrfToken()

      fetch(`/orders/${orderId}/order_items/${itemId}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          "Accept": "application/json"
        },
        body: JSON.stringify({ quantity: quantity })
      })
      .then(res => {
        if (!res.ok) console.error("Failed to update item quantity")
      })
      .catch(err => console.error("Error updating item:", err))
    }, 500)
  }

  _deleteItem(itemId, orderId) {
    const csrfToken = this._csrfToken()

    fetch(`/orders/${orderId}/order_items/${itemId}`, {
      method: "DELETE",
      headers: {
        "X-CSRF-Token": csrfToken,
        "Accept": "application/json"
      }
    })
    .then(res => {
      if (!res.ok) console.error("Failed to delete item")
    })
    .catch(err => console.error("Error deleting item:", err))
  }

  _patchOrder(orderId, data) {
    const key = `order_${orderId}`
    if (this._debounceTimers[key]) clearTimeout(this._debounceTimers[key])

    this._debounceTimers[key] = setTimeout(() => {
      const csrfToken = this._csrfToken()

      fetch(`/orders/${orderId}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          "Accept": "application/json"
        },
        body: JSON.stringify({ order: data })
      })
      .then(res => {
        if (!res.ok) console.error("Failed to update order")
      })
      .catch(err => console.error("Error updating order:", err))
    }, 500)
  }

  // --- Helpers ---

  _inputForItem(itemId) {
    return this.quantityInputTargets.find(input => input.dataset.itemId === itemId)
  }

  _rowForItem(itemId) {
    return this.itemRowTargets.find(row => row.dataset.itemId === itemId)
  }

  _cardForOrder(orderId) {
    const id = String(orderId)
    // Try Stimulus targets first
    const fromTargets = this.orderCardTargets.find(card => card.dataset.orderId === id)
    if (fromTargets) return fromTargets

    // Fallback: direct DOM query within this controller's element
    return this.element.querySelector(`[data-order-review-target="orderCard"][data-order-id="${id}"]`)
  }

  _setVerificationStatus(orderId, status) {
    const card = this._cardForOrder(orderId)
    if (card) card.dataset.verificationStatus = status
  }

  _csrfToken() {
    if (!this._cachedCsrfToken) {
      this._cachedCsrfToken = document.querySelector("meta[name='csrf-token']")?.content
    }
    return this._cachedCsrfToken
  }

  // --- Forgot Something modal ---

  openForgotSomething() {
    this._forgotItemsAddedToOrders = new Set()
    if (this.hasForgotModalTarget) {
      this.forgotModalTarget.classList.remove("hidden")
      if (this.hasForgotSearchInputTarget) {
        this.forgotSearchInputTarget.value = ""
        this.forgotSearchInputTarget.focus()
      }
      if (this.hasForgotResultsTarget) {
        this.forgotResultsTarget.innerHTML = '<p class="text-sm text-gray-400 text-center py-8">Search for a product to add to your order</p>'
      }
    }
  }

  closeForgotSomething() {
    if (this.hasForgotModalTarget) {
      this.forgotModalTarget.classList.add("hidden")
    }

    // Re-verify orders that had items added
    if (this._forgotItemsAddedToOrders && this._forgotItemsAddedToOrders.size > 0) {
      const orderIds = Array.from(this._forgotItemsAddedToOrders)
      this._forgotItemsAddedToOrders = new Set()

      fetch("/orders/retry_verification", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrfToken(),
          "Accept": "application/json"
        },
        body: JSON.stringify({ batch_id: this.batchIdValue, order_ids: orderIds })
      })
      .then(res => res.json())
      .then(data => {
        if (data.success) {
          // Show verifying state on affected orders
          orderIds.forEach(id => this._showOrderVerifying(String(id)))
          this._showVerificationBanner()
          this._startPolling()
          this._updateSubmitStates()
        }
      })
      .catch(err => console.error("Error triggering re-verification:", err))
    }
  }

  searchForgotProducts() {
    const query = this.forgotSearchInputTarget.value.trim()
    if (query.length < 3) {
      this.forgotResultsTarget.innerHTML = '<p class="text-sm text-gray-400 text-center py-12">Type at least 3 characters to search</p>'
      return
    }

    // Debounce
    if (this._forgotSearchTimer) clearTimeout(this._forgotSearchTimer)
    this._forgotSearchTimer = setTimeout(() => {
      this._doForgotSearch(query)
    }, 300)
  }

  _doForgotSearch(query) {
    this.forgotResultsTarget.innerHTML = '<p class="text-sm text-gray-400 text-center py-12">Searching...</p>'

    fetch(`/orders/search_products?q=${encodeURIComponent(query)}&batch_id=${this.batchIdValue}`, {
      headers: { "Accept": "application/json" }
    })
    .then(res => res.json())
    .then(data => {
      if (!data.results || data.results.length === 0) {
        this.forgotResultsTarget.innerHTML = '<p class="text-sm text-gray-400 text-center py-12">No products found</p>'
        return
      }

      this.forgotResultsTarget.innerHTML = data.results.map((product, i) => {
        const border = i > 0 ? 'border-t border-gray-100' : ''
        const stockDot = product.in_stock !== false
          ? '<span class="inline-block w-1.5 h-1.5 rounded-full bg-green-500 flex-shrink-0"></span>'
          : '<span class="inline-block w-1.5 h-1.5 rounded-full bg-red-400 flex-shrink-0"></span>'
        const packInfo = product.pack_size ? `<span class="text-gray-400">&middot;</span> <span>${this._escapeHtml(product.pack_size)}</span>` : ''

        return `
          <button type="button"
                  class="group w-full flex items-center justify-between px-4 py-3 text-left ${border} hover:bg-brand-orange/5 transition-colors cursor-pointer"
                  data-action="order-review#addForgotItem"
                  data-supplier-product-id="${product.id}"
                  data-order-id="${product.order_id}"
                  data-product-name="${this._escapeHtml(product.name)}"
                  data-product-price="${product.price}">
            <div class="flex-1 min-w-0 mr-4">
              <div class="flex items-center gap-2">
                ${stockDot}
                <span class="text-sm font-medium text-gray-900 truncate group-hover:text-brand-orange-dark">${this._escapeHtml(product.name)}</span>
              </div>
              <div class="flex items-center gap-1.5 mt-0.5 ml-3.5 text-xs text-gray-500">
                <span>${this._escapeHtml(product.supplier_name)}</span>
                ${packInfo}
              </div>
            </div>
            <div class="flex items-center gap-3 flex-shrink-0">
              <span class="text-sm font-semibold text-gray-900 tabular-nums">${product.price ? this._formatCurrency(product.price) : 'N/A'}</span>
              <span data-add-pill class="px-2.5 py-1 text-xs font-medium rounded-md text-brand-orange border border-brand-orange/40 group-hover:bg-brand-orange group-hover:text-white group-hover:border-brand-orange transition-colors">
                Add
              </span>
            </div>
          </button>
        `
      }).join("")
    })
    .catch(err => {
      console.error("Search error:", err)
      this.forgotResultsTarget.innerHTML = '<p class="text-sm text-red-500 text-center py-8">Search failed. Please try again.</p>'
    })
  }

  addForgotItem(event) {
    const btn = event.currentTarget
    const orderId = btn.dataset.orderId
    const supplierProductId = btn.dataset.supplierProductId
    // Pill is a child span — update IT instead of btn.textContent (which would wipe the row)
    const pill = btn.querySelector('[data-add-pill]')

    // Disable to prevent double-click
    btn.disabled = true
    btn.classList.add("opacity-50", "pointer-events-none")
    if (pill) pill.textContent = "Adding..."

    fetch(`/orders/${orderId}/order_items`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this._csrfToken(),
        "Accept": "application/json"
      },
      body: JSON.stringify({ supplier_product_id: supplierProductId, quantity: 1 })
    })
    .then(res => {
      if (!res.ok) throw new Error("Failed to add item")
      return res.json()
    })
    .then(data => {
      if (data.is_existing) {
        this._updateExistingItemRow(data.item)
      } else {
        this._insertNewItemRow(orderId, data.item, data.item.verification_pending)
      }

      // Update order totals
      this._applyServerTotals(orderId, data.order)
      this._recalculateSummary()
      this._updateMinimumForOrder(orderId, parseFloat(data.order.subtotal), data.meets_minimum)
      this._updateSubmitStates()

      // Recalculate everything (case-minimum banner/badge, per-order submit
      // button, KPI summary) — the legacy helpers above don't touch these.
      this._scheduleRecalculation()

      // Restart polling to pick up item verification results
      if (data.item.verification_pending) {
        if (!this._pollingInterval) this._startPolling()
        // Also fire an immediate poll after a short delay to catch fast completions
        setTimeout(() => this._pollVerificationStatus(), 1000)
      }

      // Track this order for re-verification on modal close
      if (this._forgotItemsAddedToOrders) {
        this._forgotItemsAddedToOrders.add(orderId)
      }

      // Show success state on pill
      if (pill) {
        pill.textContent = "Added!"
        pill.classList.remove("text-brand-orange", "border-brand-orange/40")
        pill.classList.add("bg-green-600", "text-white", "border-green-600")
      }
      setTimeout(() => {
        if (pill) {
          pill.textContent = "Add"
          pill.classList.remove("bg-green-600", "text-white", "border-green-600")
          pill.classList.add("text-brand-orange", "border-brand-orange/40")
        }
        btn.disabled = false
        btn.classList.remove("opacity-50", "pointer-events-none")
      }, 1500)
    })
    .catch(err => {
      console.error("Error adding item:", err)
      if (pill) {
        pill.textContent = "Failed"
        pill.classList.add("bg-red-500", "text-white")
      }
      setTimeout(() => {
        if (pill) {
          pill.textContent = "Add"
          pill.classList.remove("bg-red-500", "text-white")
        }
        btn.disabled = false
        btn.classList.remove("opacity-50", "pointer-events-none")
      }, 1500)
    })
  }

  _formatCurrency(amount) {
    return "$" + parseFloat(amount).toFixed(2)
  }

  _escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
