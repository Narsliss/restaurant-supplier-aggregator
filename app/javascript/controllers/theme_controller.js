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

  // Toggle: light ↔ dark
  cycle() {
    const isDark = document.documentElement.classList.contains("dark")
    const next = isDark ? "light" : "dark"
    localStorage.setItem(this.storageKey, next)
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
    let preference = this.currentPreference
    // If no preference saved, resolve system preference and persist it
    if (!preference) {
      preference = this.mediaQuery.matches ? "dark" : "light"
      localStorage.setItem(this.storageKey, preference)
    }
    const isDark = preference === "dark"

    document.documentElement.classList.toggle("dark", isDark)
    this._updateIcons(preference)
  }

  _updateIcons(preference) {
    const isDark = document.documentElement.classList.contains("dark")
    // Use plural targets to update both desktop and mobile instances
    this.lightIconTargets.forEach(el => {
      el.classList.toggle("hidden", isDark)
    })
    this.darkIconTargets.forEach(el => {
      el.classList.toggle("hidden", !isDark)
    })
    this.systemIconTargets.forEach(el => {
      el.classList.add("hidden")
    })
    this.labelTargets.forEach(el => {
      el.textContent = isDark ? "Dark" : "Light"
    })
  }

  _handleSystemChange() {
    // Only react to OS changes when in "system" mode
    if (!this.currentPreference) {
      this.applyTheme()
    }
  }
}
