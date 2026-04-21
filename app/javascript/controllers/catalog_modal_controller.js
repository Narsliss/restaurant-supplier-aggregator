import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "backdrop", "input", "results", "count"]
  static values = { url: String, addUrl: String }

  connect() {
    this.timeout = null
    this._handleKeydown = (e) => {
      if (e.key === "Escape") this.close()
    }
  }

  disconnect() {
    if (this.timeout) clearTimeout(this.timeout)
    document.removeEventListener("keydown", this._handleKeydown)
    document.body.style.overflow = ""
  }

  open() {
    this.modalTarget.classList.remove("hidden")
    document.addEventListener("keydown", this._handleKeydown)
    document.body.style.overflow = "hidden"
    setTimeout(() => this.inputTarget.focus(), 50)
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.removeEventListener("keydown", this._handleKeydown)
    document.body.style.overflow = ""
    this.inputTarget.value = ""
    this.resultsTarget.innerHTML = ""
    this.countTarget.textContent = ""
  }

  search() {
    const query = this.inputTarget.value.trim()

    if (this.timeout) clearTimeout(this.timeout)

    if (query.length < 2) {
      this.resultsTarget.innerHTML = ""
      this.countTarget.textContent = ""
      return
    }

    this.timeout = setTimeout(() => this.performSearch(query), 250)
  }

  async performSearch(query) {
    const url = new URL(this.urlValue, window.location.origin)
    url.searchParams.set("q", query)

    try {
      this.resultsTarget.innerHTML = '<div class="text-center py-8 text-gray-400">Searching...</div>'

      const response = await fetch(url, {
        headers: { "Accept": "application/json", "X-Requested-With": "XMLHttpRequest" }
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)

      const items = await response.json()
      this.renderResults(items)
    } catch (error) {
      console.error("Catalog browse error:", error)
      this.resultsTarget.innerHTML = '<div class="text-center py-8 text-red-500">Search failed. Please try again.</div>'
      this.countTarget.textContent = ""
    }
  }

  renderResults(items) {
    if (items.length === 0) {
      this.resultsTarget.innerHTML = '<div class="text-center py-12 text-gray-400 text-sm">No products found</div>'
      this.countTarget.textContent = ""
      return
    }

    this.countTarget.textContent = `${items.length} result${items.length === 1 ? "" : "s"}`

    this.resultsTarget.innerHTML = items.map((item, i) => {
      const border = i > 0 ? 'border-t border-gray-100' : ''
      const stockDot = item.in_stock
        ? '<span class="inline-block w-1.5 h-1.5 rounded-full bg-green-500 flex-shrink-0"></span>'
        : '<span class="inline-block w-1.5 h-1.5 rounded-full bg-red-400 flex-shrink-0"></span>'

      const packInfo = item.pack_size ? `<span class="text-gray-400">&middot;</span> <span>${this.escapeHtml(item.pack_size)}</span>` : ""

      return `
        <form method="post" action="${this.addUrlValue}" data-turbo="true" class="${border}">
          <input type="hidden" name="authenticity_token" value="${this.csrfToken()}">
          <input type="hidden" name="supplier_product_id" value="${item.id}">
          <button type="submit" class="group w-full flex items-center justify-between px-4 py-3 text-left hover:bg-brand-orange/5 transition-colors cursor-pointer">
            <div class="flex-1 min-w-0 mr-4">
              <div class="flex items-center gap-2">
                ${stockDot}
                <span class="text-sm font-medium text-gray-900 truncate group-hover:text-brand-orange-dark">${this.escapeHtml(item.name)}</span>
              </div>
              <div class="flex items-center gap-1.5 mt-0.5 ml-3.5 text-xs text-gray-500">
                <span>${this.escapeHtml(item.supplier_name)}</span>
                ${packInfo}
              </div>
            </div>
            <div class="flex items-center gap-3 flex-shrink-0">
              <span class="text-sm font-semibold text-gray-900 tabular-nums">${this.escapeHtml(item.price)}</span>
              <span class="px-2.5 py-1 text-xs font-medium rounded-md text-brand-orange border border-brand-orange/40 group-hover:bg-brand-orange group-hover:text-white group-hover:border-brand-orange transition-colors">
                Add
              </span>
            </div>
          </button>
        </form>
      `
    }).join("")
  }

  escapeHtml(text) {
    if (!text) return ""
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }

  csrfToken() {
    const meta = document.querySelector('meta[name="csrf-token"]')
    return meta ? meta.content : ""
  }
}
