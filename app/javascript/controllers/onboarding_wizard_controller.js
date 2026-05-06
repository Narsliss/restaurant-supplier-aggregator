import { Controller } from "@hotwired/stimulus"
import { stepsFor, flowFor, nextStepName, isLastStep } from "onboarding/steps"

// Mounts the onboarding wizard overlay (scrim + spotlight ring + modal panel).
// Boots from the data attributes set by app/views/shared/_onboarding_wizard.html.erb.
//
// Writes go through three endpoints (advance/complete/skip), all of which
// touch ONLY onboarding_progresses. The wizard never directly mutates
// application data — when a step asks the user to do something (create org,
// connect supplier, etc.), they leave the wizard panel and use the real
// form on the real page. The wizard's job is to spotlight where to go.
export default class extends Controller {
  static targets = ["scrim", "panel", "title", "body", "image", "primaryCta", "skipCta", "stepIndicator", "picker"]
  static values = {
    role:           String,
    currentStep:    String,
    completedSteps: { type: Array,  default: [] },
    imagePaths:     { type: Object, default: {} },
    suppliersUrl:   String,
    advanceUrl:     String,
    completeUrl:    String,
    skipUrl:        String,
    csrf:           String,
  }

  connect() {
    if (!this.roleValue) {
      this.hide()
      return
    }
    this.render()
  }

  disconnect() {
    this.clearSpotlight()
  }

  // --- Stimulus actions (bound from view) ---

  advance(event) {
    event?.preventDefault()

    if (this.atFinalStep()) {
      this.completeWizard()
      return
    }

    const next = nextStepName(this.roleValue, this.currentStepValue)
    if (!next) {
      this.completeWizard()
      return
    }

    this.post(this.advanceUrlValue, { next_step: next }).then((state) => {
      if (!state) return
      this.currentStepValue    = state.current_step
      this.completedStepsValue = state.completed_steps || []
      if (state.completed_at || state.dismissed_at) {
        this.hide()
        return
      }
      this.render()
    })
  }

  skip(event) {
    event?.preventDefault()
    this.post(this.skipUrlValue, {}).then(() => this.hide())
  }

  // --- Rendering ---

  render() {
    const step = this.currentStepDescriptor()
    if (!step) {
      this.hide()
      return
    }

    if (this.hasTitleTarget)      this.titleTarget.textContent = step.title || ""
    if (this.hasBodyTarget)       this.bodyTarget.innerHTML    = step.body  || ""
    if (this.hasPrimaryCtaTarget) this.primaryCtaTarget.textContent = step.primaryCta || "Got it →"

    // Steps without a spotlight (welcome, done) render as a centered modal
    // for stronger visual presence; spotlight steps stay bottom-anchored
    // so they don't cover the highlighted element.
    if (this.hasPanelTarget) {
      if (step.spotlight) {
        this.panelTarget.classList.remove("onboarding-panel--centered")
      } else {
        this.panelTarget.classList.add("onboarding-panel--centered")
      }
    }

    if (this.hasImageTarget) {
      const url = step.image ? this.imagePathsValue[step.image] : null
      if (url) {
        this.imageTarget.innerHTML = `<a href="${url}" target="_blank" rel="noopener" class="onboarding-panel-screenshot-link"><img src="${url}" alt="" class="onboarding-panel-screenshot" /></a>`
        this.imageTarget.removeAttribute("hidden")
      } else {
        this.imageTarget.innerHTML = ""
        this.imageTarget.setAttribute("hidden", "true")
      }
    }

    // Supplier picker — special render for the suppliers step.
    // Fetches /onboarding/suppliers JSON and draws Connect / ✓ Connected
    // cards inside the panel.
    if (this.hasPickerTarget) {
      if (this.currentStepValue === "suppliers") {
        this.renderSuppliersPicker()
      } else {
        this.pickerTarget.innerHTML = ""
        this.pickerTarget.setAttribute("hidden", "true")
      }
    }

    if (this.hasStepIndicatorTarget) {
      const flow = flowFor(this.roleValue)
      const idx  = flow.indexOf(this.currentStepValue) + 1
      this.stepIndicatorTarget.textContent = idx > 0 ? `${idx} of ${flow.length}` : ""
    }

    this.applySpotlight(step.spotlight)
    this.show()
  }

  show() {
    this.element.removeAttribute("hidden")
  }

  hide() {
    this.element.setAttribute("hidden", "true")
    this.clearSpotlight()
  }

  // --- Suppliers picker ---

  renderSuppliersPicker() {
    if (!this.suppliersUrlValue) return

    this.pickerTarget.removeAttribute("hidden")
    this.pickerTarget.innerHTML = `<div class="onboarding-panel-picker-loading text-xs text-gray-500">Loading suppliers…</div>`

    fetch(this.suppliersUrlValue, {
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    })
      .then((r) => (r.ok ? r.json() : null))
      .then((data) => {
        if (!data?.suppliers) {
          this.pickerTarget.innerHTML = ""
          return
        }
        this.pickerTarget.innerHTML = this.buildPickerHtml(data.suppliers)
      })
      .catch(() => {
        this.pickerTarget.innerHTML = ""
      })
  }

  buildPickerHtml(suppliers) {
    const cards = suppliers
      .map((s) => {
        if (s.connected) {
          return `<div class="onboarding-panel-picker-card onboarding-panel-picker-card--connected">
            <span class="onboarding-panel-picker-card-name">${this.escape(s.name)}</span>
            <span class="onboarding-panel-picker-card-status">✓ Connected</span>
          </div>`
        }
        const url = `/supplier_credentials/new?supplier_id=${s.id}&from_wizard=1`
        return `<div class="onboarding-panel-picker-card">
          <span class="onboarding-panel-picker-card-name">${this.escape(s.name)}</span>
          <a class="onboarding-panel-picker-card-action" href="${url}">Connect →</a>
        </div>`
      })
      .join("")

    return `<div class="onboarding-panel-picker">${cards}</div>`
  }

  escape(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }

  // --- Internals ---

  completeWizard() {
    this.post(this.completeUrlValue, {}).then(() => this.hide())
  }

  currentStepDescriptor() {
    const steps = stepsFor(this.roleValue)
    return steps[this.currentStepValue] || null
  }

  atFinalStep() {
    return isLastStep(this.roleValue, this.currentStepValue)
  }

  // Apply the spotlight ring to the first DOM target found. Accepts either
  // a single target id or an array of fallback ids (first match wins).
  // If the target lives inside a closed dropdown, opens it first.
  applySpotlight(target) {
    this.clearSpotlight()
    if (!target) return

    const candidates = Array.isArray(target) ? target : [target]
    let el = null
    for (const id of candidates) {
      el = document.querySelector(`[data-onboarding-target="${id}"]`)
      if (el) break
    }
    if (!el) return

    const dropdown = el.closest('[data-controller~="dropdown"]')
    if (dropdown) {
      const menu = dropdown.querySelector('[data-dropdown-target="menu"]')
      if (menu && menu.classList.contains("hidden")) {
        menu.classList.remove("hidden")
        this._openedDropdownMenu = menu
      }
    }

    el.classList.add("onboarding-spotlight")
    this._spotlightEl = el
  }

  clearSpotlight() {
    if (this._spotlightEl) {
      this._spotlightEl.classList.remove("onboarding-spotlight")
      this._spotlightEl = null
    }
    if (this._openedDropdownMenu) {
      this._openedDropdownMenu.classList.add("hidden")
      this._openedDropdownMenu = null
    }
  }

  post(url, body) {
    if (!url) return Promise.resolve(null)

    return fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        "Accept":       "application/json",
        "X-CSRF-Token": this.csrfValue,
      },
      body: JSON.stringify(body),
    })
      .then((r) => (r.ok ? r.json() : null))
      .catch(() => null)
  }
}
