import { Controller } from "@hotwired/stimulus"
import { stepsFor, flowFor, nextStepName, isLastStep } from "onboarding/steps"

// Mounts the onboarding wizard overlay (scrim + spotlight ring + modal panel).
// Boots from the data attributes set by app/views/shared/_onboarding_wizard.html.erb.
//
// The wizard is purely informational. Each step has a title, body copy,
// optional embedded screenshot, and optional spotlight target. The user
// follows the spotlight to the real page (Supplier Credentials, Order
// Lists, etc.) to perform actions there. The wizard never duplicates
// real CRUD surfaces — it just points the way.
//
// Writes go through three endpoints (advance/complete/skip), all of which
// touch ONLY onboarding_progresses.
export default class extends Controller {
  static targets = [
    "scrim", "panel", "title", "body", "image", "primaryCta", "backCta",
    "stepIndicator", "livesAt", "footer", "stepForm",
  ]
  static values = {
    role:           String,
    currentStep:    String,
    completedSteps: { type: Array,  default: [] },
    imagePaths:     { type: Object, default: {} },
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
    this._onStepFormFrameLoad = this.onStepFormFrameLoad.bind(this)
    if (this.hasStepFormTarget) {
      this.stepFormTarget.addEventListener("turbo:frame-load", this._onStepFormFrameLoad)
    }
    this.render()
  }

  disconnect() {
    this.clearSpotlight()
    document.body.classList.remove("onboarding-spotlight-active")
    if (this.hasStepFormTarget && this._onStepFormFrameLoad) {
      this.stepFormTarget.removeEventListener("turbo:frame-load", this._onStepFormFrameLoad)
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

    // Inline form: when a step has a formUrl, load it into the turbo-frame.
    // Submission goes to the real Rails controller; on success the
    // controller responds with a saved-marker frame and onStepFormFrameLoad
    // advances the wizard.
    if (this.hasStepFormTarget) {
      if (step.formUrl) {
        const desiredSrc = new URL(step.formUrl, window.location.origin).toString()
        if (this.stepFormTarget.getAttribute("src") !== desiredSrc) {
          this.stepFormTarget.setAttribute("src", desiredSrc)
        }
        this.stepFormTarget.removeAttribute("hidden")
      } else {
        this.stepFormTarget.removeAttribute("src")
        this.stepFormTarget.innerHTML = ""
        this.stepFormTarget.setAttribute("hidden", "true")
      }
    }

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

    // Hide Back on the first step; hide it on the done step too.
    if (this.hasBackCtaTarget) {
      const flow = flowFor(this.roleValue)
      const isFirst = flow.indexOf(this.currentStepValue) <= 0
      if (isFirst || step.phase === "done") {
        this.backCtaTarget.setAttribute("hidden", "true")
      } else {
        this.backCtaTarget.removeAttribute("hidden")
      }
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
    document.body.classList.remove("onboarding-spotlight-active")
  }

  // --- Inline form frame ---

  // Fired by Turbo each time the stepForm frame loads new content. The
  // server signals "form saved successfully" by including a child element
  // with [data-onboarding-form-saved] inside the frame; we detect that
  // and advance the wizard to the next step.
  onStepFormFrameLoad() {
    if (!this.hasStepFormTarget) return
    const savedMarker = this.stepFormTarget.querySelector("[data-onboarding-form-saved]")
    if (!savedMarker) return

    // Empty the frame so coming back to this step (via Back) re-fetches
    // a fresh form.
    this.stepFormTarget.removeAttribute("src")
    this.stepFormTarget.innerHTML = ""

    this.advance()
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

  escape(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
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
