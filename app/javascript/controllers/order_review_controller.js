import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "quantityInput", "lineTotal", "itemRow", "orderCard",
    "orderSubtotal", "orderSubtotalFooter", "orderItemCount",
    "summaryOrders", "summaryItems", "summaryTotal", "summarySavings",
    "minimumBadge", "minimumWarning", "minimumShortfall",
    "warningsArea", "submitAllBtn", "supplierSubmitBtn", "summaryBar",
    "deliveryDate",
    // Verification targets
    "verificationBanner", "verificationProgress",
    "priceChangeBanner", "verificationFailedBanner", "verificationFailedMessage",
    "verifyingIndicator", "verifiedBadge", "priceChangedBadge", "verifyFailedBadge",
    "priceChangeDetails", "priceChangeList", "priceDiff", "unitPriceDisplay",
    "verificationErrorDetails", "verificationErrorText",
    "suggestionsSection"
  ]

  static values = {
    batchId: String,
    verifying: Boolean,
    aggregatedListId: String
  }

  connect() {
    this._debounceTimers = {}
    this._pollingInterval = null
    this._updateSubmitStates()

    // Always start polling — verification kicks off automatically on page load
    if (this.verifyingValue) {
      this._startPolling()
    }
  }

  disconnect() {
    this._stopPolling()
  }

  // --- Quantity adjustments ---

  incrementItem(event) {
    const btn = event.currentTarget
    const itemId = btn.dataset.itemId
    const input = this._inputForItem(itemId)
    if (!input) return
    const newQty = (parseInt(input.value) || 0) + 1
    input.value = newQty
    this._onQuantityChange(itemId, btn.dataset.orderId, newQty)
  }

  decrementItem(event) {
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
    const input = event.currentTarget
    const newQty = parseInt(input.value) || 1
    if (newQty < 1) {
      input.value = 1
      return
    }
    this._onQuantityChange(input.dataset.itemId, input.dataset.orderId, newQty)
  }

  _onQuantityChange(itemId, orderId, quantity) {
    // Instant client-side update
    this._updateLineTotal(itemId, quantity)
    this._recalculateOrderTotals(orderId)
    this._recalculateSummary()
    this._updateMinimumStatus()

    // Debounced server persist
    this._debouncePatch(itemId, orderId, quantity)
  }

  _updateLineTotal(itemId, quantity) {
    const row = this._rowForItem(itemId)
    if (!row) return
    const unitPrice = parseFloat(row.dataset.unitPrice) || 0
    const lineTotal = unitPrice * quantity

    this.lineTotalTargets.forEach(el => {
      if (el.dataset.itemId === itemId) {
        el.textContent = this._formatCurrency(lineTotal)
      }
    })
  }

  // --- Remove item ---

  removeItem(event) {
    const btn = event.currentTarget
    const itemId = btn.dataset.itemId
    const orderId = btn.dataset.orderId

    // Remove from DOM immediately
    this.itemRowTargets.forEach(row => {
      if (row.dataset.itemId === itemId) {
        row.remove()
      }
    })

    this._recalculateOrderTotals(orderId)
    this._recalculateSummary()
    this._updateMinimumStatus()

    // Check if order card has no items left
    const card = this._cardForOrder(orderId)
    if (card) {
      const remaining = card.querySelectorAll("[data-order-review-target='itemRow']").length
      if (remaining === 0) {
        card.remove()
        this._recalculateSummary()
        this._updateMinimumStatus()
      }
    }

    // Server DELETE
    this._deleteItem(itemId, orderId)
  }

  // --- Delivery date / notes ---

  updateDeliveryDate(event) {
    const input = event.currentTarget
    const orderId = input.dataset.orderId
    this._patchOrder(orderId, { delivery_date: input.value })
    this._updateSubmitStates()
  }

  updateNotes(event) {
    const input = event.currentTarget
    const orderId = input.dataset.orderId
    this._patchOrder(orderId, { notes: input.value })
  }

  // --- Quick-add suggestions ---

  addSuggestion(event) {
    const btn = event.currentTarget
    const orderId = String(btn.dataset.orderId)
    const supplierProductId = btn.dataset.supplierProductId

    // Disable immediately to prevent double-click
    btn.disabled = true
    btn.classList.add("opacity-50", "cursor-not-allowed")

    fetch(`/order-history/${orderId}/order_items`, {
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
        this._insertNewItemRow(orderId, data.item)
      }

      // Remove the suggestion pill
      btn.remove()

      // Update order totals from server response (most accurate)
      this._applyServerTotals(orderId, data.order, data.meets_minimum)

      // Recalculate summary bar and minimum status from DOM
      this._recalculateSummary()
      this._updateMinimumStatus()
    })
    .catch(err => {
      console.error("Error adding suggestion:", err)
      // Re-enable button on network/server failure
      btn.disabled = false
      btn.classList.remove("opacity-50", "cursor-not-allowed")
    })
  }

  _insertNewItemRow(orderId, item) {
    const card = this._cardForOrder(orderId)
    if (!card) {
      console.warn("[_insertNewItemRow] Card not found for orderId:", orderId)
      return
    }

    const name = item.name || ""
    const sku = item.sku || ""

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
          <span class="text-gray-900" data-order-review-target="unitPriceDisplay" data-item-id="${item.id}">${this._formatCurrency(item.unit_price)}</span>
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
            <span class="text-xs text-gray-500" data-order-review-target="unitPriceDisplay" data-item-id="${item.id}">${this._formatCurrency(item.unit_price)} each</span>
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

  _hideSuggestionsIfMinimumMet(orderId) {
    const card = this._cardForOrder(orderId)
    if (!card) return

    const minimum = parseFloat(card.dataset.minimum) || 0
    if (minimum === 0) return

    const rows = card.querySelectorAll("[data-order-review-target='itemRow']")
    let subtotal = 0
    rows.forEach(row => {
      const unitPrice = parseFloat(row.dataset.unitPrice) || 0
      const input = row.querySelector("[data-order-review-target='quantityInput']")
      const qty = input ? (parseInt(input.value) || 0) : 0
      subtotal += unitPrice * qty
    })

    if (subtotal >= minimum) {
      this.suggestionsSectionTargets.forEach(el => {
        if (el.dataset.orderId === orderId) {
          el.style.display = "none"
        }
      })
    }
  }

  // Apply server-returned order totals to DOM (more accurate than client recalculation)
  _applyServerTotals(orderId, orderData, meetsMinimum) {
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
    fetch(`/order-history/skip_verification`, {
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
    fetch(`/order-history/skip_verification`, {
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
    fetch(`/order-history/retry_verification`, {
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
    fetch(`/order-history/retry_verification`, {
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
    fetch(`/order-history/verification_status?batch_id=${this.batchIdValue}`, {
      headers: { "Accept": "application/json" }
    })
    .then(res => res.json())
    .then(data => {
      this._updateVerificationUI(data)
      if (data.summary.all_complete) {
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

    // If no more orders on page (all submitted), redirect
    if (this.orderCardTargets.length === 0) {
      window.location.href = "/order-history"
    }

    // Update submit button states based on verification results
    this._updateSubmitStates()
  }

  // --- Per-order verification UI updates ---

  _showOrderVerifying(orderId) {
    this._hideOrderVerificationUI(orderId)
    this._setVerificationStatus(orderId, "verifying")
    this.verifyingIndicatorTargets.forEach(el => {
      if (el.dataset.orderId === orderId) el.classList.remove("hidden")
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
  }

  // --- Recalculation helpers ---

  _recalculateOrderTotals(orderId) {
    const card = this._cardForOrder(orderId)
    if (!card) return

    const rows = card.querySelectorAll("[data-order-review-target='itemRow']")
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
      const rows = card.querySelectorAll("[data-order-review-target='itemRow']")
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

      // Calculate current subtotal for this card
      const rows = card.querySelectorAll("[data-order-review-target='itemRow']")
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
        card.classList.remove("ring-2", "ring-yellow-400")
      } else {
        card.classList.add("ring-2", "ring-yellow-400")
      }

      // Update warning banners
      this.minimumWarningTargets.forEach(warning => {
        if (warning.dataset.orderId === orderId) {
          warning.style.display = meetsMinium ? "none" : "block"
          if (!meetsMinium) {
            const supplierName = card.dataset.supplierName
            const shortfall = minimum - subtotal
            warning.querySelector("p").innerHTML = `
              <span class="font-medium">Warning:</span>
              ${supplierName} order minimum not met.
              <span class="text-yellow-600">
                Current: ${this._formatCurrency(subtotal)},
                Need: ${this._formatCurrency(shortfall)} more
                (Minimum: ${this._formatCurrency(minimum)})
              </span>
            `
          }
        }
      })

      // Hide suggestions when minimum is met
      this._hideSuggestionsIfMinimumMet(orderId)
    })

    this._updateSubmitStates()
  }

  _hasValidDeliveryDate(orderId) {
    const dateInput = this.deliveryDateTargets.find(el => el.dataset.orderId === orderId)
    if (!dateInput || !dateInput.value) return false
    const selected = new Date(dateInput.value + "T00:00:00")
    const today = new Date()
    today.setHours(0, 0, 0, 0)
    return selected > today
  }

  _updateSubmitStates() {
    let allCanSubmit = true

    this.orderCardTargets.forEach(card => {
      const orderId = card.dataset.orderId
      const minimum = parseFloat(card.dataset.minimum) || 0
      const verificationStatus = card.dataset.verificationStatus

      // Calculate subtotal
      const rows = card.querySelectorAll("[data-order-review-target='itemRow']")
      let subtotal = 0
      rows.forEach(row => {
        const unitPrice = parseFloat(row.dataset.unitPrice) || 0
        const input = row.querySelector("[data-order-review-target='quantityInput']")
        const qty = input ? (parseInt(input.value) || 0) : 0
        subtotal += unitPrice * qty
      })

      const meetsMinimum = minimum === 0 || subtotal >= minimum
      const hasDate = this._hasValidDeliveryDate(orderId)
      const isVerified = ["verified", "price_changed", "skipped"].includes(verificationStatus)
      const canSubmit = meetsMinimum && hasDate && isVerified

      if (!canSubmit) allCanSubmit = false

      // Update per-supplier submit button
      this.supplierSubmitBtnTargets.forEach(btn => {
        if (btn.dataset.orderId === orderId) {
          if (canSubmit) {
            btn.disabled = false
            btn.classList.remove("bg-gray-300", "cursor-not-allowed")
            btn.classList.add("bg-brand-orange", "hover:bg-brand-orange-dark", "cursor-pointer")
          } else {
            btn.disabled = true
            btn.classList.add("bg-gray-300", "cursor-not-allowed")
            btn.classList.remove("bg-brand-orange", "hover:bg-brand-orange-dark", "cursor-pointer")
          }
        }
      })
    })

    // Update "Submit All" button
    this.submitAllBtnTargets.forEach(btn => {
      if (allCanSubmit && this.orderCardTargets.length > 0) {
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

  _checkIfAllDone() {
    // If no more order cards, redirect to order history
    if (this.orderCardTargets.length === 0) {
      window.location.href = "/order-history"
    }
  }

  // --- Server communication ---

  _debouncePatch(itemId, orderId, quantity) {
    const key = `item_${itemId}`
    if (this._debounceTimers[key]) clearTimeout(this._debounceTimers[key])

    this._debounceTimers[key] = setTimeout(() => {
      const csrfToken = this._csrfToken()

      fetch(`/order-history/${orderId}/order_items/${itemId}`, {
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

    fetch(`/order-history/${orderId}/order_items/${itemId}`, {
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

      fetch(`/order-history/${orderId}`, {
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
    return document.querySelector("meta[name='csrf-token']")?.content
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
