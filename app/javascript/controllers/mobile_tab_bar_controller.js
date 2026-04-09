import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab"]

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

  highlight() {
    const path = window.location.pathname

    this.tabTargets.forEach(tab => {
      const tabPath = tab.dataset.path
      const isActive = tabPath === "/" ? path === "/" : path.startsWith(tabPath)

      if (isActive) {
        tab.style.color = "#4A7C59"
        tab.style.borderBottom = "2px solid #4A7C59"
      } else {
        tab.style.color = "#9CA3AF"
        tab.style.borderBottom = "2px solid transparent"
      }
    })
  }
}
