import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "results", "productId"]
  static values = {
    url: { type: String, default: "/products/search" }
  }

  connect() {
    this.resultsTarget.classList.add("hidden")
    this.timeout = null
  }

  disconnect() {
    if (this.timeout) {
      clearTimeout(this.timeout)
    }
  }

  search() {
    const query = this.inputTarget.value.trim()

    // Clear previous timeout
    if (this.timeout) {
      clearTimeout(this.timeout)
    }

    // Hide results if query is too short
    if (query.length < 2) {
      this.resultsTarget.classList.add("hidden")
      return
    }

    // Debounce search
    this.timeout = setTimeout(() => {
      this.performSearch(query)
    }, 300)
  }

  async performSearch(query) {
    try {
      const response = await fetch(`${this.urlValue}?q=${encodeURIComponent(query)}`, {
        headers: {
          "Accept": "application/json",
          "X-Requested-With": "XMLHttpRequest"
        }
      })

      if (!response.ok) {
        throw new Error(`HTTP error: ${response.status}`)
      }

      const products = await response.json()
      this.displayResults(products)
    } catch (error) {
      console.error("Product search error:", error)
      this.resultsTarget.innerHTML = `<div class="p-3 text-red-600 text-sm">Search error. Please try again.</div>`
      this.resultsTarget.classList.remove("hidden")
    }
  }

  displayResults(products) {
    if (products.length === 0) {
      this.resultsTarget.innerHTML = `<div class="p-3 text-gray-500 text-sm">No products found</div>`
      this.resultsTarget.classList.remove("hidden")
      return
    }

    const html = products.map(product => {
      const priceInfo = product.prices && product.prices.length > 0
        ? product.prices.map(p => `${p.supplier}: $${p.price || "N/A"}`).join(", ")
        : "No pricing info"

      return `
        <button type="button"
          class="w-full text-left px-3 py-2 hover:bg-gray-100 focus:bg-gray-100 focus:outline-none border-b border-gray-100 last:border-0"
          data-action="click->product-search#select"
          data-product-id="${product.id}"
          data-product-name="${this.escapeHtml(product.name)}">
          <div class="font-medium text-gray-900 text-sm">${this.escapeHtml(product.name)}</div>
          <div class="text-xs text-gray-500">${product.category || "Uncategorized"} &bull; ${this.escapeHtml(priceInfo)}</div>
        </button>
      `
    }).join("")

    this.resultsTarget.innerHTML = html
    this.resultsTarget.classList.remove("hidden")
  }

  select(event) {
    const button = event.currentTarget
    const productId = button.dataset.productId
    const productName = button.dataset.productName

    // Set the hidden product_id field
    this.productIdTarget.value = productId

    // Update the search input to show the selected product
    this.inputTarget.value = productName

    // Hide results
    this.resultsTarget.classList.add("hidden")

    // Add visual feedback that a product was selected
    this.inputTarget.classList.add("border-green-500", "ring-1", "ring-green-500")
    setTimeout(() => {
      this.inputTarget.classList.remove("border-green-500", "ring-1", "ring-green-500")
    }, 1500)
  }

  hideResults(event) {
    // Delay hiding to allow click events to fire
    setTimeout(() => {
      if (!this.element.contains(document.activeElement)) {
        this.resultsTarget.classList.add("hidden")
      }
    }, 200)
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
