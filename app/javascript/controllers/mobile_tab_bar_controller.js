import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["tab"]

  connect() {
    this.highlight()
  }

  highlight() {
    const path = window.location.pathname

    this.tabTargets.forEach(tab => {
      const tabPath = tab.dataset.path
      const isActive = tabPath === "/" ? path === "/" : path.startsWith(tabPath)

      if (isActive) {
        // Match mockup: .tab-active { color: #4A7C59; border-bottom: 2px solid #4A7C59; }
        tab.style.color = "#4A7C59"
        tab.style.borderBottom = "2px solid #4A7C59"
      } else {
        // Match mockup: .tab-inactive { color: #9CA3AF; }
        tab.style.color = "#9CA3AF"
        tab.style.borderBottom = "2px solid transparent"
      }
    })
  }
}
