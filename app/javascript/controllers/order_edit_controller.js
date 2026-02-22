import { Controller } from "@hotwired/stimulus"

/**
 * Inline editing controller for the order show page (pending orders only).
 * Allows ± quantity adjustment, item removal, and order submission.
 * Reuses the existing OrderItemsController JSON endpoints (PATCH, DELETE).
 *
 * Usage:
 *   <div data-controller="order-edit"
 *        data-order-edit-order-id-value="123"
 *        data-order-edit-minimum-value="150">
 */
export default class extends Controller {
  static values = {
    orderId: Number,
    minimum: Number
  }

  static targets = [
    "itemRow", "quantityInput", "lineTotal",
    "orderTotal", "orderTotalFooter", "itemCount",
    "minimumWarning", "minimumShortfall",
    "submitButton", "deliveryDate"
  ]

  connect() {
    this._debounceTimers = {}
  }

  // --- Quantity adjustments ---

  incrementItem(event) {
    const btn = event.currentTarget
    const itemId = btn.dataset.itemId
    const input = this._inputForItem(itemId)
    if (!input) return
    const newQty = (parseInt(input.value) || 0) + 1
    input.value = newQty
    this._onQuantityChange(itemId, newQty)
  }

  decrementItem(event) {
    const btn = event.currentTarget
    const itemId = btn.dataset.itemId
    const input = this._inputForItem(itemId)
    if (!input) return
    const current = parseInt(input.value) || 0
    if (current <= 1) return
    const newQty = current - 1
    input.value = newQty
    this._onQuantityChange(itemId, newQty)
  }

  updateQuantity(event) {
    const input = event.currentTarget
    const newQty = parseInt(input.value) || 1
    if (newQty < 1) {
      input.value = 1
      return
    }
    this._onQuantityChange(input.dataset.itemId, newQty)
  }

  _onQuantityChange(itemId, quantity) {
    // Sync quantity across desktop + mobile duplicate inputs
    this.quantityInputTargets.forEach(input => {
      if (input.dataset.itemId === itemId) {
        input.value = quantity
      }
    })

    // Instant client-side update
    this._updateLineTotal(itemId, quantity)
    this._recalculateTotal()

    // Debounced server persist
    this._debouncePatch(itemId, quantity)
  }

  _updateLineTotal(itemId, quantity) {
    let unitPrice = 0
    this.itemRowTargets.forEach(row => {
      if (row.dataset.itemId === itemId && parseFloat(row.dataset.unitPrice)) {
        unitPrice = parseFloat(row.dataset.unitPrice)
      }
    })
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

    // Remove from DOM immediately (both desktop + mobile)
    this.itemRowTargets.forEach(row => {
      if (row.dataset.itemId === itemId) {
        row.remove()
      }
    })

    this._recalculateTotal()

    // Server DELETE
    this._deleteItem(itemId)
  }

  // --- Delivery date & notes ---

  updateDeliveryDate(event) {
    const value = event.currentTarget.value
    this._patchOrder({ delivery_date: value })
    this._updateSubmitState()
  }

  updateNotes(event) {
    this._patchOrder({ notes: event.currentTarget.value })
  }

  // --- Submit order ---

  submitOrder(event) {
    // Submit is handled by the form button_to, but we can prevent if needed
    // The button_to already posts to submit_order_path
  }

  // --- Recalculation ---

  _recalculateTotal() {
    // Filter to visible rows only (page has desktop + mobile markup)
    const rows = this.itemRowTargets.filter(row => row.offsetParent !== null)
    let subtotal = 0
    let itemCount = 0

    rows.forEach(row => {
      const unitPrice = parseFloat(row.dataset.unitPrice) || 0
      const input = row.querySelector("[data-order-edit-target='quantityInput']")
      const qty = input ? (parseInt(input.value) || 0) : 0
      subtotal += unitPrice * qty
      itemCount++
    })

    // Update total displays
    if (this.hasOrderTotalTarget) {
      this.orderTotalTarget.textContent = this._formatCurrency(subtotal)
    }
    this.orderTotalFooterTargets.forEach(el => {
      el.textContent = this._formatCurrency(subtotal)
    })

    // Update item count
    if (this.hasItemCountTarget) {
      this.itemCountTarget.textContent = itemCount
    }

    // Check minimum
    this._updateMinimumStatus(subtotal)
    this._updateSubmitState()
  }

  _updateMinimumStatus(subtotal) {
    const minimum = this.minimumValue || 0
    if (minimum === 0) return

    const meetsMinimum = subtotal >= minimum

    if (this.hasMinimumWarningTarget) {
      if (meetsMinimum) {
        this.minimumWarningTarget.classList.add("hidden")
      } else {
        this.minimumWarningTarget.classList.remove("hidden")
      }
    }

    if (this.hasMinimumShortfallTarget) {
      if (meetsMinimum) {
        this.minimumShortfallTarget.style.display = "none"
      } else {
        const shortfall = minimum - subtotal
        this.minimumShortfallTarget.style.display = "inline"
        this.minimumShortfallTarget.textContent =
          `Current: ${this._formatCurrency(subtotal)}, Need: ${this._formatCurrency(shortfall)} more (Minimum: ${this._formatCurrency(minimum)})`
      }
    }
  }

  _updateSubmitState() {
    if (!this.hasSubmitButtonTarget) return

    const minimum = this.minimumValue || 0
    const rows = this.itemRowTargets.filter(row => row.offsetParent !== null)

    let subtotal = 0
    rows.forEach(row => {
      const unitPrice = parseFloat(row.dataset.unitPrice) || 0
      const input = row.querySelector("[data-order-edit-target='quantityInput']")
      const qty = input ? (parseInt(input.value) || 0) : 0
      subtotal += unitPrice * qty
    })

    const meetsMinimum = minimum === 0 || subtotal >= minimum
    const hasItems = rows.length > 0

    const canSubmit = meetsMinimum && hasItems

    if (canSubmit) {
      this.submitButtonTarget.disabled = false
      this.submitButtonTarget.classList.remove("bg-gray-300", "cursor-not-allowed")
      this.submitButtonTarget.classList.add("bg-brand-orange", "hover:bg-brand-orange-dark")
    } else {
      this.submitButtonTarget.disabled = true
      this.submitButtonTarget.classList.add("bg-gray-300", "cursor-not-allowed")
      this.submitButtonTarget.classList.remove("bg-brand-orange", "hover:bg-brand-orange-dark")
    }
  }

  // --- Server communication ---

  _debouncePatch(itemId, quantity) {
    const key = `item_${itemId}`
    if (this._debounceTimers[key]) clearTimeout(this._debounceTimers[key])

    this._debounceTimers[key] = setTimeout(() => {
      fetch(`/order-history/${this.orderIdValue}/order_items/${itemId}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrfToken(),
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

  _deleteItem(itemId) {
    fetch(`/order-history/${this.orderIdValue}/order_items/${itemId}`, {
      method: "DELETE",
      headers: {
        "X-CSRF-Token": this._csrfToken(),
        "Accept": "application/json"
      }
    })
    .then(res => {
      if (!res.ok) console.error("Failed to delete item")
      return res.json()
    })
    .then(data => {
      // If all items removed, redirect to order history
      if (data && data.order_removed) {
        window.location.href = "/order-history"
      }
    })
    .catch(err => console.error("Error deleting item:", err))
  }

  _patchOrder(data) {
    const key = "order_patch"
    if (this._debounceTimers[key]) clearTimeout(this._debounceTimers[key])

    this._debounceTimers[key] = setTimeout(() => {
      fetch(`/order-history/${this.orderIdValue}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this._csrfToken(),
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

  _csrfToken() {
    return document.querySelector("meta[name='csrf-token']")?.content
  }

  _formatCurrency(amount) {
    return "$" + parseFloat(amount).toFixed(2)
  }
}
