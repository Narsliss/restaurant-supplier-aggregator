import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "quantityInput", "lineTotal", "itemRow", "orderCard",
    "orderSubtotal", "orderSubtotalFooter", "orderItemCount",
    "summaryOrders", "summaryItems", "summaryTotal", "summarySavings",
    "minimumBadge", "minimumWarning", "minimumShortfall",
    "warningsArea", "submitAllBtn", "supplierSubmitBtn", "summaryBar",
    "deliveryDate"
  ]

  static values = { batchId: String }

  connect() {
    this._debounceTimers = {}
    this._updateSubmitStates()
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
      const canSubmit = meetsMinimum && hasDate

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
        if (btn.tagName === "SPAN") {
          btn.style.display = "none"
        } else {
          btn.disabled = false
          btn.classList.remove("bg-gray-300", "cursor-not-allowed")
          btn.classList.add("bg-brand-orange", "hover:bg-brand-orange-dark", "cursor-pointer")
        }
      } else {
        if (btn.tagName === "SPAN") {
          btn.style.display = "inline-block"
        } else {
          btn.disabled = true
          btn.classList.add("bg-gray-300", "cursor-not-allowed")
          btn.classList.remove("bg-brand-orange", "hover:bg-brand-orange-dark", "cursor-pointer")
        }
      }
    })
  }

  // --- Server communication ---

  _debouncePatch(itemId, orderId, quantity) {
    const key = `item_${itemId}`
    if (this._debounceTimers[key]) clearTimeout(this._debounceTimers[key])

    this._debounceTimers[key] = setTimeout(() => {
      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

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
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

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
      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

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
    return this.orderCardTargets.find(card => card.dataset.orderId === orderId)
  }

  _formatCurrency(amount) {
    return "$" + amount.toFixed(2)
  }
}
