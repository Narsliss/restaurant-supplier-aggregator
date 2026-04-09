import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab", "fabCircle"]

  connect() {
    this.highlight()

    // Show loading state on tapped tab during Turbo navigation
    this._onBeforeFetch = this._showLoading.bind(this)
    this._onLoad = this._hideLoading.bind(this)
    document.addEventListener("turbo:before-fetch-request", this._onBeforeFetch)
    document.addEventListener("turbo:load", this._onLoad)
    // Safety net: also clear on render in case turbo:load doesn't fire
    document.addEventListener("turbo:before-render", this._onLoad)
  }

  disconnect() {
    document.removeEventListener("turbo:before-fetch-request", this._onBeforeFetch)
    document.removeEventListener("turbo:load", this._onLoad)
    document.removeEventListener("turbo:before-render", this._onLoad)
    if (this._loadingTimeout) clearTimeout(this._loadingTimeout)
  }

  _showLoading(event) {
    // Only react to full-page navigation, not JSON/API fetches (e.g., order-status polling)
    const accept = event.detail?.fetchOptions?.headers?.Accept || ""
    if (!accept.includes("text/html")) return

    const url = event.detail?.url
    if (!url) return

    // Clean up any existing spinners first (prevents doubles)
    this.element.querySelectorAll("[data-loading-spinner]").forEach(s => s.remove())
    this.tabTargets.forEach(tab => {
      const icon = tab.querySelector("svg")
      if (icon) icon.style.display = ""
    })

    const targetPath = new URL(url).pathname
    this.tabTargets.forEach(tab => {
      const tabPath = tab.dataset.path
      if (!tabPath) return
      const matches = tabPath === "/" ? targetPath === "/" : targetPath.startsWith(tabPath)
      if (matches) {
        // Replace the SVG icon with a spinner
        const icon = tab.querySelector("svg")
        if (icon) {
          icon.style.display = "none"
          const spinner = document.createElement("span")
          spinner.className = "tab-loading-spinner"
          spinner.dataset.loadingSpinner = "true"
          icon.parentNode.insertBefore(spinner, icon)
        }
        tab.style.color = "#4A7C59"
      }
    })

    // Safety: auto-hide after 8s so spinner never gets stuck
    this._loadingTimeout = setTimeout(() => this._hideLoading(), 8000)
  }

  _hideLoading() {
    if (this._loadingTimeout) clearTimeout(this._loadingTimeout)
    // Remove any loading spinners and restore icons
    this.element.querySelectorAll("[data-loading-spinner]").forEach(s => s.remove())
    this.tabTargets.forEach(tab => {
      const icon = tab.querySelector("svg")
      if (icon) icon.style.display = ""
    })
    this.highlight()
  }

  // Paths that belong to the ordering flow (FAB), not the History tab
  static orderFlowPaths = ["/orders/select_list", "/orders/review", "/orders/new", "/aggregated_lists/"]

  _isOrderFlow(path) {
    return this.constructor.orderFlowPaths.some(p => path.startsWith(p))
  }

  highlight() {
    const path = window.location.pathname
    const inOrderFlow = this._isOrderFlow(path)

    this.tabTargets.forEach(tab => {
      const tabPath = tab.dataset.path
      let isActive

      if (tabPath === "/") {
        isActive = path === "/"
      } else if (tabPath === "/orders/select_list") {
        // FAB: active when in order flow
        isActive = inOrderFlow
      } else if (tabPath === "/orders") {
        // History: active for /orders but NOT order flow pages
        isActive = path.startsWith("/orders") && !inOrderFlow
      } else {
        isActive = path.startsWith(tabPath)
      }

      if (isActive) {
        tab.style.color = "#4A7C59"
        // No underline for FAB — it highlights via circle glow instead
        tab.style.borderBottom = tabPath === "/orders/select_list"
          ? "2px solid transparent"
          : "2px solid #4A7C59"
      } else {
        tab.style.color = "#9CA3AF"
        tab.style.borderBottom = "2px solid transparent"
      }
    })

    // Highlight FAB circle when in order flow
    if (this.hasFabCircleTarget) {
      if (inOrderFlow) {
        this.fabCircleTarget.style.boxShadow = "0 0 0 3px rgba(74, 124, 89, 0.3), 0 4px 12px rgba(74, 124, 89, 0.4)"
      } else {
        this.fabCircleTarget.style.boxShadow = "0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -2px rgba(0, 0, 0, 0.1)"
      }
    }
  }
}
