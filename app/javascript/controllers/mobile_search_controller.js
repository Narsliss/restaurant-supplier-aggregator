import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "results", "empty", "placeholder"]
  static values = { url: String }

  connect() {
    this._debounce = null
  }

  search() {
    clearTimeout(this._debounce)
    const query = this.inputTarget.value.trim()

    if (query.length < 2) {
      this.resultsTarget.innerHTML = ""
      this.emptyTarget.classList.add("hidden")
      this.placeholderTarget.classList.remove("hidden")
      return
    }

    this.placeholderTarget.classList.add("hidden")

    this._debounce = setTimeout(() => {
      this._fetch(query)
    }, 300)
  }

  async _fetch(query) {
    try {
      const url = `${this.urlValue}?q=${encodeURIComponent(query)}`
      const response = await fetch(url, {
        headers: { "Accept": "application/json" }
      })
      const products = await response.json()

      if (products.length === 0) {
        this.resultsTarget.innerHTML = ""
        this.emptyTarget.classList.remove("hidden")
        return
      }

      this.emptyTarget.classList.add("hidden")
      this.resultsTarget.innerHTML = products.map(p => this._renderCard(p)).join("")
    } catch (e) {
      console.error("Search error:", e)
    }
  }

  _renderCard(product) {
    const stockBadge = product.in_stock === false
      ? `<span class="text-[9px] font-bold text-red-500 bg-red-50 px-1.5 py-0.5 rounded-full">Out of stock</span>`
      : ""

    return `
      <div class="bg-white rounded-xl border border-gray-200 shadow-sm p-3">
        <div class="flex items-start justify-between gap-2">
          <div class="flex-1 min-w-0">
            <p class="text-sm font-semibold text-gray-900 truncate">${this._escapeHtml(product.name)}</p>
            <div class="flex items-center gap-2 mt-0.5">
              <span class="text-[10px] font-bold text-brand-green bg-green-50 px-1.5 py-0.5 rounded">${this._escapeHtml(product.supplier_name)}</span>
              ${product.pack_size ? `<span class="text-[10px] text-gray-400">${this._escapeHtml(product.pack_size)}</span>` : ""}
              ${stockBadge}
            </div>
          </div>
          <p class="text-sm font-bold text-brand-navy flex-shrink-0">${product.price}</p>
        </div>
      </div>
    `
  }

  _escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
