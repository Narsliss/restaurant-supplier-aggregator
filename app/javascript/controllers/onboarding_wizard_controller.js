import { Controller } from "@hotwired/stimulus"
import consumer from "../channels/consumer"
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
    "twoFa", "twoFaSupplier", "twoFaPrompt", "twoFaTimer", "twoFaCode",
    "twoFaError", "twoFaSubmit",
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

    // Subscribe to TwoFactorChannel so we can intercept verification
    // challenges and render them inline in the wizard panel instead of
    // letting the global 2FA modal pop up.
    this._twoFaSubscription = consumer.subscriptions.create("TwoFactorChannel", {
      received: this.onTwoFaMessage.bind(this),
    })

    this.render()
  }

  disconnect() {
    this.clearSpotlight()
    this.clearPickerRefresh()
    this.stopTwoFaTimer()
    this._twoFaSubscription?.unsubscribe()
    this._twoFaSubscription = null
    window.__onboardingWizardHandlesTwoFa = false
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

  // Picker → load NEW supplier form inline. Bound from "Connect →" cards.
  connectSupplier(event) {
    event?.preventDefault()
    const supplierId = event.currentTarget?.dataset?.supplierId
    if (!supplierId || !this.hasSupplierFormTarget) return

    this.showSupplierForm()
    this.supplierFormTarget.setAttribute(
      "src",
      `/supplier_credentials/new?supplier_id=${encodeURIComponent(supplierId)}&from_wizard=1`,
    )
  }

  // Picker → load EDIT form for an existing failed/expired credential.
  // Bound from "⚠ Reconnect" cards.
  reconnectSupplier(event) {
    event?.preventDefault()
    const credentialId = event.currentTarget?.dataset?.credentialId
    if (!credentialId || !this.hasSupplierFormTarget) return

    this.showSupplierForm()
    this.supplierFormTarget.setAttribute(
      "src",
      `/supplier_credentials/${encodeURIComponent(credentialId)}/edit?from_wizard=1`,
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

    // Suppliers step → render picker; anything else → hide picker / form /
    // 2FA view, stop polling, drop any 2FA flag.
    if (this.currentStepValue === "suppliers") {
      // If we're already in the middle of a 2FA challenge, keep that view
      // up — leaving the user mid-verification would lose the session.
      if (!this._twoFaSessionToken) {
        this.showPicker()
        this.renderSuppliersPicker()
      }
    } else {
      this.clearPickerRefresh()
      if (this.hasPickerTarget) {
        this.pickerTarget.innerHTML = ""
        this.pickerTarget.setAttribute("hidden", "true")
      }
      if (this.hasSupplierFormTarget) {
        this.supplierFormTarget.setAttribute("hidden", "true")
      }
      if (this.hasTwoFaTarget) {
        this.twoFaTarget.setAttribute("hidden", "true")
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
    this.clearPickerRefresh()
    document.body.classList.remove("onboarding-spotlight-active")
  }

  showPicker() {
    if (this.hasPickerTarget)       this.pickerTarget.removeAttribute("hidden")
    if (this.hasSupplierFormTarget) this.supplierFormTarget.setAttribute("hidden", "true")
    if (this.hasTwoFaTarget)        this.twoFaTarget.setAttribute("hidden", "true")
    this.togglePanelCtas(true)
  }

  showSupplierForm() {
    if (this.hasPickerTarget)       this.pickerTarget.setAttribute("hidden", "true")
    if (this.hasSupplierFormTarget) this.supplierFormTarget.removeAttribute("hidden")
    if (this.hasTwoFaTarget)        this.twoFaTarget.setAttribute("hidden", "true")
    // The form has its own Cancel + Save buttons; hide the wizard's CTAs
    // so they don't compete with it.
    this.togglePanelCtas(false)
  }

  showTwoFa() {
    if (this.hasPickerTarget)       this.pickerTarget.setAttribute("hidden", "true")
    if (this.hasSupplierFormTarget) this.supplierFormTarget.setAttribute("hidden", "true")
    if (this.hasTwoFaTarget)        this.twoFaTarget.removeAttribute("hidden")
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

    this.fetchPickerData({ initial: true })
  }

  // Fetches /onboarding/suppliers.json and re-renders the picker. If any
  // supplier is in `pending` status (validation job still running, possibly
  // waiting on a 2FA code), schedules another fetch a few seconds later so
  // the picker auto-updates to ✓ Connected or ⚠ Reconnect when the
  // background job finishes — no manual refresh required.
  fetchPickerData({ initial = false } = {}) {
    fetch(this.suppliersUrlValue, {
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    })
      .then((r) => (r.ok ? r.json() : null))
      .then((data) => {
        if (!data?.suppliers) {
          if (initial) this.pickerTarget.innerHTML = ""
          return
        }
        this.pickerTarget.innerHTML = this.buildPickerHtml(data.suppliers)

        const hasPending = data.suppliers.some((s) => s.credential_status === "pending")
        if (hasPending) {
          this.schedulePickerRefresh()
        } else {
          this.clearPickerRefresh()
        }
      })
      .catch(() => {
        if (initial) this.pickerTarget.innerHTML = ""
      })
  }

  schedulePickerRefresh() {
    this.clearPickerRefresh()
    this._pickerRefreshTimer = setTimeout(() => {
      // Only re-fetch if we're still on the suppliers step and the wizard
      // is still showing.
      const stillOnSuppliers = this.currentStepValue === "suppliers"
      const stillVisible = !this.element.hasAttribute("hidden")
      if (stillOnSuppliers && stillVisible) {
        this.fetchPickerData()
      }
    }, 4000)
  }

  clearPickerRefresh() {
    if (this._pickerRefreshTimer) {
      clearTimeout(this._pickerRefreshTimer)
      this._pickerRefreshTimer = null
    }
  }

  buildPickerHtml(suppliers) {
    const cards = suppliers
      .map((s) => this.buildPickerCard(s))
      .join("")

    return `<div class="onboarding-panel-picker">${cards}</div>`
  }

  buildPickerCard(s) {
    const name = this.escape(s.name)
    const status = s.credential_status

    // Active: green, ✓ Connected (no action — already done)
    if (status === "active") {
      return `<div class="onboarding-panel-picker-card onboarding-panel-picker-card--connected">
        <span class="onboarding-panel-picker-card-name">${name}</span>
        <span class="onboarding-panel-picker-card-status">✓ Connected</span>
      </div>`
    }

    // Pending: validation running, possibly waiting on user 2FA code
    if (status === "pending") {
      return `<div class="onboarding-panel-picker-card onboarding-panel-picker-card--pending">
        <span class="onboarding-panel-picker-card-name">${name}</span>
        <span class="onboarding-panel-picker-card-status onboarding-panel-picker-card-status--pending">Validating…</span>
      </div>`
    }

    // Failed/expired/hold: credential exists but needs to be fixed.
    // Open the EDIT form for the existing credential rather than trying
    // to create a duplicate (which the controller would reject). Label
    // matches the actual state so the user knows what's wrong.
    if (s.credential_id && status) {
      const label = this.statusActionLabel(status)
      return `<div class="onboarding-panel-picker-card onboarding-panel-picker-card--needs-attention">
        <span class="onboarding-panel-picker-card-name">${name}</span>
        <button type="button"
                class="onboarding-panel-picker-card-action onboarding-panel-picker-card-action--reconnect"
                data-action="click->onboarding-wizard#reconnectSupplier"
                data-credential-id="${s.credential_id}">${label}</button>
      </div>`
    }

    // No credential yet: fresh "Connect →" creates a new credential.
    return `<div class="onboarding-panel-picker-card">
      <span class="onboarding-panel-picker-card-name">${name}</span>
      <button type="button"
              class="onboarding-panel-picker-card-action"
              data-action="click->onboarding-wizard#connectSupplier"
              data-supplier-id="${s.id}">Connect →</button>
    </div>`
  }

  escape(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }

  statusActionLabel(status) {
    switch (status) {
      case "failed":  return "⚠ Failed"
      case "expired": return "⚠ Expired"
      case "hold":    return "⚠ On hold"
      default:        return "⚠ Fix"
    }
  }

  // --- 2FA inline verification ---

  onTwoFaMessage(data) {
    switch (data.type) {
      case "two_fa_required":
        this.handleTwoFaRequired(data)
        break
      case "code_result":
        this.handleTwoFaCodeResult(data)
        break
      case "cancelled":
        this.exitTwoFa()
        break
      case "error":
        this.showTwoFaError(data.message || "Verification error")
        break
    }
  }

  handleTwoFaRequired(data) {
    // Only intercept if the wizard is currently on the suppliers step.
    // Otherwise let the global 2FA modal handle it (e.g. session-refresh
    // 2FA challenges that fire from background jobs).
    if (this.currentStepValue !== "suppliers") return

    // Tell the global 2FA controller to skip — wizard owns this challenge.
    window.__onboardingWizardHandlesTwoFa = true

    this._twoFaSessionToken = data.session_token
    this._twoFaExpiresAt    = data.expires_at

    if (this.hasTwoFaSupplierTarget) {
      this.twoFaSupplierTarget.textContent = data.supplier_name || "your supplier"
    }
    if (this.hasTwoFaPromptTarget) {
      this.twoFaPromptTarget.textContent = data.prompt_message || "Enter the verification code we sent."
    }
    if (this.hasTwoFaCodeTarget) {
      this.twoFaCodeTarget.value = ""
    }
    this.hideTwoFaError()
    this.enableTwoFaSubmit()
    this.startTwoFaTimer()
    this.showTwoFa()
    if (this.hasTwoFaCodeTarget) this.twoFaCodeTarget.focus()
  }

  handleTwoFaCodeResult(data) {
    this.enableTwoFaSubmit()
    if (this.hasTwoFaSubmitTarget) this.twoFaSubmitTarget.textContent = "Verify"

    if (data.success) {
      this.exitTwoFa()
      // Re-fetch the picker so the just-verified supplier flips to ✓ Connected.
      // (The credential's status transitions in the background; polling will
      // catch up either way, but this is faster.)
      this.fetchPickerData()
      return
    }

    let msg = data.error || "Verification failed"
    if (data.attempts_remaining) msg += ` (${data.attempts_remaining} attempts remaining)`
    this.showTwoFaError(msg)

    if (this.hasTwoFaCodeTarget) {
      this.twoFaCodeTarget.value = ""
      this.twoFaCodeTarget.focus()
    }

    if (data.can_retry === false) {
      this.disableTwoFaSubmit()
      if (this.hasTwoFaSubmitTarget) this.twoFaSubmitTarget.textContent = "Max attempts reached"
    }
  }

  twoFaSubmit(event) {
    event?.preventDefault()
    if (!this._twoFaSubscription) return
    if (!this.hasTwoFaCodeTarget) return

    const code = this.twoFaCodeTarget.value.trim()
    if (!code) {
      this.showTwoFaError("Please enter a verification code")
      return
    }

    this.disableTwoFaSubmit()
    if (this.hasTwoFaSubmitTarget) this.twoFaSubmitTarget.textContent = "Verifying…"
    this._twoFaSubscription.perform("submit_code", {
      session_token: this._twoFaSessionToken,
      code: code,
    })
  }

  twoFaCancel(event) {
    event?.preventDefault()
    if (this._twoFaSubscription && this._twoFaSessionToken) {
      this._twoFaSubscription.perform("cancel", {
        session_token: this._twoFaSessionToken,
      })
    }
    this.exitTwoFa()
    this.fetchPickerData()
  }

  twoFaKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.twoFaSubmit()
    }
  }

  exitTwoFa() {
    window.__onboardingWizardHandlesTwoFa = false
    this._twoFaSessionToken = null
    this._twoFaExpiresAt    = null
    this.stopTwoFaTimer()
    this.hideTwoFaError()
    if (this.hasTwoFaCodeTarget) this.twoFaCodeTarget.value = ""
    this.showPicker()
  }

  startTwoFaTimer() {
    this.stopTwoFaTimer()
    if (!this._twoFaExpiresAt || !this.hasTwoFaTimerTarget) return

    const expiresAt = new Date(this._twoFaExpiresAt)
    const tick = () => {
      const remaining = Math.max(0, Math.floor((expiresAt - new Date()) / 1000))
      if (remaining <= 0) {
        this.twoFaTimerTarget.textContent = "Expired"
        this.disableTwoFaSubmit()
        this.stopTwoFaTimer()
        return
      }
      const m = Math.floor(remaining / 60)
      const s = remaining % 60
      this.twoFaTimerTarget.textContent = `${m}:${s.toString().padStart(2, "0")}`
    }
    tick()
    this._twoFaTimerInterval = setInterval(tick, 1000)
  }

  stopTwoFaTimer() {
    if (this._twoFaTimerInterval) {
      clearInterval(this._twoFaTimerInterval)
      this._twoFaTimerInterval = null
    }
  }

  showTwoFaError(message) {
    if (!this.hasTwoFaErrorTarget) return
    this.twoFaErrorTarget.textContent = message
    this.twoFaErrorTarget.removeAttribute("hidden")
  }

  hideTwoFaError() {
    if (!this.hasTwoFaErrorTarget) return
    this.twoFaErrorTarget.textContent = ""
    this.twoFaErrorTarget.setAttribute("hidden", "true")
  }

  enableTwoFaSubmit() {
    if (this.hasTwoFaSubmitTarget) this.twoFaSubmitTarget.disabled = false
  }

  disableTwoFaSubmit() {
    if (this.hasTwoFaSubmitTarget) this.twoFaSubmitTarget.disabled = true
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
