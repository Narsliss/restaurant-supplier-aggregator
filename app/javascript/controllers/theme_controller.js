import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["lightIcon", "darkIcon", "systemIcon", "label"]

  connect() {
    this.storageKey = "supplierhub-theme"
    this.mediaQuery = window.matchMedia("(prefers-color-scheme: dark)")
    this._handleSystemChange = this._handleSystemChange.bind(this)
    this.mediaQuery.addEventListener("change", this._handleSystemChange)
    this.applyTheme()
  }

  disconnect() {
    this.mediaQuery.removeEventListener("change", this._handleSystemChange)
  }

  get currentPreference() {
    return localStorage.getItem(this.storageKey) // "light", "dark", or null (system)
  }

  // Cycle: system → light → dark → system …
  cycle() {
    const current = this.currentPreference
    let next
    if (current === null) {
      next = "light"
    } else if (current === "light") {
      next = "dark"
    } else {
      next = null // system
    }

    if (next) {
      localStorage.setItem(this.storageKey, next)
    } else {
      localStorage.removeItem(this.storageKey)
    }

    this.applyTheme()
  }

  setLight() {
    localStorage.setItem(this.storageKey, "light")
    this.applyTheme()
  }

  setDark() {
    localStorage.setItem(this.storageKey, "dark")
    this.applyTheme()
  }

  setSystem() {
    localStorage.removeItem(this.storageKey)
    this.applyTheme()
  }

  applyTheme() {
    const preference = this.currentPreference
    const isDark = preference === "dark" ||
      (!preference && this.mediaQuery.matches)

    document.documentElement.classList.toggle("dark", isDark)
    this._updateIcons(preference)
  }

  _updateIcons(preference) {
    // Use plural targets to update both desktop and mobile instances
    this.lightIconTargets.forEach(el => {
      el.classList.toggle("hidden", preference !== "light")
    })
    this.darkIconTargets.forEach(el => {
      el.classList.toggle("hidden", preference !== "dark")
    })
    this.systemIconTargets.forEach(el => {
      el.classList.toggle("hidden", preference !== null)
    })
    this.labelTargets.forEach(el => {
      const labels = { light: "Light", dark: "Dark" }
      el.textContent = labels[preference] || "System"
    })
  }

  _handleSystemChange() {
    // Only react to OS changes when in "system" mode
    if (!this.currentPreference) {
      this.applyTheme()
    }
  }
}
