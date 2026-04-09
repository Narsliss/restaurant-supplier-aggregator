import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "results", "empty", "placeholder"]
  static values = { url: String, addUrl: String, csrf: String, orderLists: Array }

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

  async addToList(event) {
    const btn = event.currentTarget
    const productId = btn.dataset.productId
    const card = btn.closest("[data-product-card]")
    const listSelector = card.querySelector("[data-list-select]")

    if (!listSelector) return

    const listId = listSelector.value
    if (!listId) return

    btn.disabled = true
    btn.textContent = "Adding..."

    try {
      const formData = new FormData()
      formData.append("supplier_product_id", productId)
      formData.append("order_list_id", listId)

      const response = await fetch(this.addUrlValue, {
        method: "POST",
        headers: {
          "X-CSRF-Token": this.csrfValue,
          "Accept": "text/html"
        },
        body: formData,
        redirect: "follow"
      })

      if (response.ok || response.redirected) {
        btn.textContent = "Added!"
        btn.classList.remove("bg-brand-green")
        btn.classList.add("bg-green-600")
        setTimeout(() => {
          btn.disabled = false
          btn.textContent = "Add"
          btn.classList.remove("bg-green-600")
          btn.classList.add("bg-brand-green")
        }, 2000)
      } else {
        btn.textContent = "Error"
        setTimeout(() => { btn.disabled = false; btn.textContent = "Add" }, 2000)
      }
    } catch (e) {
      console.error("Add to list error:", e)
      btn.disabled = false
      btn.textContent = "Add"
    }
  }

  _renderCard(product) {
    const stockBadge = product.in_stock === false
      ? `<span class="text-[9px] font-bold text-red-500 bg-red-50 px-1.5 py-0.5 rounded-full">Out of stock</span>`
      : ""

    const lists = this.orderListsValue || []
    const listOptions = lists.map(l =>
      `<option value="${l.id}">${this._escapeHtml(l.name)}</option>`
    ).join("")

    const addSection = lists.length > 0 ? `
      <div class="mt-2 pt-2 border-t border-gray-100 flex items-center gap-2">
        <select data-list-select class="flex-1 min-w-0 text-xs border-gray-200 rounded-lg py-1.5 focus:border-brand-green focus:ring-brand-green" style="max-width: calc(100% - 4rem);">
          ${listOptions}
        </select>
        <button type="button"
                data-product-id="${product.id}"
                data-action="click->mobile-search#addToList"
                class="bg-brand-green text-white text-xs font-semibold px-3 py-1.5 rounded-lg flex-shrink-0">
          Add
        </button>
      </div>
    ` : ""

    return `
      <div class="bg-white rounded-xl border border-gray-200 shadow-sm p-3" data-product-card>
        <div class="flex items-start justify-between gap-2">
          <div class="flex-1 min-w-0">
            <p class="text-sm font-semibold text-gray-900 truncate">${this._escapeHtml(product.name)}</p>
            <div class="flex items-center gap-2 mt-0.5 flex-wrap">
              <span class="text-[10px] font-bold text-brand-green bg-green-50 px-1.5 py-0.5 rounded">${this._escapeHtml(product.supplier_name)}</span>
              ${product.pack_size ? `<span class="text-[10px] text-gray-400">${this._escapeHtml(product.pack_size)}</span>` : ""}
              ${stockBadge}
            </div>
          </div>
          <p class="text-sm font-bold text-brand-navy flex-shrink-0">${product.price}</p>
        </div>
        ${addSection}
      </div>
    `
  }

  _escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
