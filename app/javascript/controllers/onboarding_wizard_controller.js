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
//
// EXCEPTION: the suppliers step embeds /supplier_credentials/new inline via
// a Turbo Frame. The user fills out the REAL form, which POSTs to the REAL
// SupplierCredentialsController. The wizard never bypasses controllers.
export default class extends Controller {
  static targets = [
    "scrim", "panel", "title", "body", "image", "primaryCta", "skipCta", "backCta",
    "stepIndicator", "livesAt", "picker", "supplierForm", "footer",
  ]
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
    this._onFrameLoad = this.onSupplierFrameLoad.bind(this)
    if (this.hasSupplierFormTarget) {
      this.supplierFormTarget.addEventListener("turbo:frame-load", this._onFrameLoad)
    }
    this.render()
  }

  disconnect() {
    this.clearSpotlight()
    document.body.classList.remove("onboarding-spotlight-active")
    if (this.hasSupplierFormTarget && this._onFrameLoad) {
      this.supplierFormTarget.removeEventListener("turbo:frame-load", this._onFrameLoad)
    }
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

  // ← Back — go to the previous step in the flow.
  back(event) {
    event?.preventDefault()

    const flow = flowFor(this.roleValue)
    const i = flow.indexOf(this.currentStepValue)
    if (i <= 0) return  // already on first step

    const prev = flow[i - 1]
    this.post(this.advanceUrlValue, { next_step: prev }).then((state) => {
      if (!state) return
      this.currentStepValue    = state.current_step
      this.completedStepsValue = state.completed_steps || []
      this.render()
    })
  }

  // Picker → load supplier form inline. Bound from generated picker cards.
  connectSupplier(event) {
    event?.preventDefault()
    const supplierId = event.currentTarget?.dataset?.supplierId
    if (!supplierId) return

    if (!this.hasSupplierFormTarget) return

    // Switch the panel to "form mode": hide picker, show empty frame, set src
    // (Turbo will fetch and replace the frame's contents).
    this.showSupplierForm()
    this.supplierFormTarget.setAttribute(
      "src",
      `/supplier_credentials/new?supplier_id=${encodeURIComponent(supplierId)}&from_wizard=1`,
    )
  }

  // "← Back to suppliers" link inside the loaded form returns to picker mode.
  backToPicker(event) {
    event?.preventDefault()
    this.showPicker()
    if (this.hasSupplierFormTarget) {
      // Empty the frame so the next Connect → triggers a fresh fetch.
      this.supplierFormTarget.removeAttribute("src")
      this.supplierFormTarget.innerHTML = ""
    }
  }

  // --- Frame load handler (success detection after form submit) ---

  onSupplierFrameLoad(event) {
    if (!this.hasSupplierFormTarget) return

    // After /supplier_credentials#create runs in from_wizard mode, the
    // response includes an empty marker div [data-onboarding-saved] inside
    // the frame. We detect it here, then flip back to the picker.
    const savedMarker = this.supplierFormTarget.querySelector("[data-onboarding-saved]")
    if (savedMarker) {
      // Re-render the picker (which will re-fetch and show the new
      // supplier's ✓ Connected state).
      this.showPicker()
      this.supplierFormTarget.removeAttribute("src")
      this.supplierFormTarget.innerHTML = ""
      this.renderSuppliersPicker()
    }
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

    // Phase + step indicator: "SETUP · 3 OF 10 · OPTIONAL"
    if (this.hasStepIndicatorTarget) {
      this.stepIndicatorTarget.textContent = this.formatPhaseIndicator(step)
    }

    // Lives-at breadcrumb: "↗ Lives at\nAvatar → Team"
    if (this.hasLivesAtTarget) {
      if (step.livesAt && step.livesAt.length > 0) {
        const path = step.livesAt.join(" → ")
        this.livesAtTarget.innerHTML = `
          <span class="onboarding-panel-livesat-label">↗ Lives at</span>
          <span class="onboarding-panel-livesat-path">${this.escape(path)}</span>
        `
        this.livesAtTarget.removeAttribute("hidden")
      } else {
        this.livesAtTarget.innerHTML = ""
        this.livesAtTarget.setAttribute("hidden", "true")
      }
    }

    // Hide Back on the first step; hide Skip + Back on the done step.
    if (this.hasBackCtaTarget) {
      const flow = flowFor(this.roleValue)
      const isFirst = flow.indexOf(this.currentStepValue) <= 0
      if (isFirst || step.phase === "done") {
        this.backCtaTarget.setAttribute("hidden", "true")
      } else {
        this.backCtaTarget.removeAttribute("hidden")
      }
    }
    if (this.hasSkipCtaTarget) {
      if (step.phase === "done") {
        this.skipCtaTarget.setAttribute("hidden", "true")
      } else {
        this.skipCtaTarget.removeAttribute("hidden")
      }
    }

    // Body class controls whether the sticky nav stays bright above the
    // scrim (spotlight steps) or gets dimmed under it (welcome / done).
    if (step.spotlight) {
      document.body.classList.add("onboarding-spotlight-active")
    } else {
      document.body.classList.remove("onboarding-spotlight-active")
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

    // Suppliers step → render picker; anything else → hide picker + form.
    if (this.currentStepValue === "suppliers") {
      this.showPicker()
      this.renderSuppliersPicker()
    } else {
      if (this.hasPickerTarget) {
        this.pickerTarget.innerHTML = ""
        this.pickerTarget.setAttribute("hidden", "true")
      }
      if (this.hasSupplierFormTarget) {
        this.supplierFormTarget.setAttribute("hidden", "true")
      }
    }

    this.applySpotlight(step.spotlight)
    this.show()
  }

  // "SETUP · 3 OF 10 · OPTIONAL" / "TOUR · 7 OF 10" / "INTRO" / "DONE"
  formatPhaseIndicator(step) {
    const flow = flowFor(this.roleValue)
    const idx  = flow.indexOf(this.currentStepValue) + 1
    const total = flow.length

    const phaseLabel = (step.phase || "tour").toUpperCase()
    const parts = [phaseLabel]

    if (step.phase !== "intro" && step.phase !== "done" && idx > 0) {
      parts.push(`${idx} of ${total}`.toUpperCase())
    }

    if (step.optional) parts.push("OPTIONAL")

    return parts.join(" · ")
  }

  show() {
    this.element.removeAttribute("hidden")
  }

  hide() {
    this.element.setAttribute("hidden", "true")
    this.clearSpotlight()
    document.body.classList.remove("onboarding-spotlight-active")
  }

  showPicker() {
    if (this.hasPickerTarget) this.pickerTarget.removeAttribute("hidden")
    if (this.hasSupplierFormTarget) this.supplierFormTarget.setAttribute("hidden", "true")
    this.togglePanelCtas(true)
  }

  showSupplierForm() {
    if (this.hasPickerTarget) this.pickerTarget.setAttribute("hidden", "true")
    if (this.hasSupplierFormTarget) this.supplierFormTarget.removeAttribute("hidden")
    // The form has its own Cancel + Save buttons; hide the wizard's CTAs
    // so they don't compete with it.
    this.togglePanelCtas(false)
  }

  togglePanelCtas(visible) {
    if (this.hasFooterTarget) {
      this.footerTarget.style.display = visible ? "" : "none"
    }
  }

  // --- Suppliers picker ---

  renderSuppliersPicker() {
    if (!this.suppliersUrlValue || !this.hasPickerTarget) return

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
        return `<div class="onboarding-panel-picker-card">
          <span class="onboarding-panel-picker-card-name">${this.escape(s.name)}</span>
          <button type="button"
                  class="onboarding-panel-picker-card-action"
                  data-action="click->onboarding-wizard#connectSupplier"
                  data-supplier-id="${s.id}">Connect →</button>
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
