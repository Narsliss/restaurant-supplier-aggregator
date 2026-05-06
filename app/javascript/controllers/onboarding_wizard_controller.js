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
  static targets = ["scrim", "panel", "title", "body", "primaryCta", "skipCta", "stepIndicator"]
  static values = {
    role:        String,  // "owner" | "chef" | "manager"
    currentStep: String,
    advanceUrl:  String,
    completeUrl: String,
    skipUrl:     String,
    csrf:        String,
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
      this.currentStepValue = state.current_step
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

  applySpotlight(targetId) {
    this.clearSpotlight()
    if (!targetId) return

    const el = document.querySelector(`[data-onboarding-target="${targetId}"]`)
    if (!el) return

    el.classList.add("onboarding-spotlight")
    this._spotlightEl = el
  }

  clearSpotlight() {
    if (this._spotlightEl) {
      this._spotlightEl.classList.remove("onboarding-spotlight")
      this._spotlightEl = null
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
