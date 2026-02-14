import { Controller } from "@hotwired/stimulus"

// Manages the full validate → 2FA code entry → result flow for a single
// supplier credential card, entirely client-side (no page reloads).
//
// States:  idle → validating → awaiting_code → verifying → success / failed
export default class extends Controller {
  static targets = [
    "statusBadge",       // the badge span (Active / Pending / Failed / etc.)
    "errorBlock",        // the red error box
    "errorText",         // the text inside the error box
    "validateBtn",       // the Validate button
    "tfaBlock",          // 2FA inline form container (hidden by default)
    "tfaPrompt",         // prompt text from the server
    "tfaCodeInput",      // the code <input>
    "tfaSubmitBtn",      // the Verify button
    "tfaTimer",          // countdown text
    "tfaMessage",        // extra message area (e.g. "Code expired, new one sent")
  ]

  static values = {
    credentialId: Number,
    statusUrl: String,     // GET endpoint for polling status
    validateUrl: String,   // POST endpoint to start validation
    submitCodeUrl: String, // POST endpoint to submit 2FA code
    credentialStatus: String, // server-rendered credential status (pending, active, failed, etc.)
  }

  connect() {
    this.polling = false
    this.timerInterval = null
    this.currentState = "idle"
    console.log(`[credential-validator] connected for credential ${this.credentialIdValue}`)

    // If the credential is pending (e.g. just created with a 2FA supplier),
    // auto-start polling so the 2FA code input appears without a manual refresh.
    if (this.credentialStatusValue === "pending") {
      this.showState("validating")
      this.startPolling()
      return
    }

    // If the 2FA block is already visible on page load (server-rendered pending state),
    // auto-start polling so updates appear without a manual refresh.
    if (this.hasTfaBlockTarget && !this.tfaBlockTarget.classList.contains("hidden")) {
      this.currentState = "awaiting_code"
      this.startPolling()
    }
  }

  disconnect() {
    this.stopPolling()
    this.stopTimer()
  }

  // ── Validate button clicked ──────────────────────────────────────
  async startValidation(event) {
    event.preventDefault()
    console.log(`[credential-validator] startValidation for credential ${this.credentialIdValue}`)
    this.showState("validating")

    try {
      const resp = await this.postJSON(this.validateUrlValue)
      console.log(`[credential-validator] validate response:`, resp)
      if (resp.status === "already_active") {
        // Already validated — show flash and reset to idle state
        this.showState("success")
        this.showAlreadyActiveFlash(resp.message)
      } else if (resp.status === "validating" || resp.status === "two_fa_required") {
        // Async validation (PPO) — start polling for the 2FA request
        this.startPolling()
      } else if (resp.status === "active") {
        this.showState("success")
      } else {
        this.showState("failed", resp.message || "Validation failed")
      }
    } catch (err) {
      console.error(`[credential-validator] validate error:`, err)
      this.showState("failed", err.message || "Request failed")
    }
  }

  // ── Code submission ──────────────────────────────────────────────
  async submitCode(event) {
    event.preventDefault()
    const code = this.tfaCodeInputTarget.value.trim()
    if (!code) return

    console.log(`[credential-validator] submitting code: ${code}`)
    this.showState("verifying")

    try {
      const resp = await this.postJSON(this.submitCodeUrlValue, { code })
      console.log(`[credential-validator] submitCode response:`, resp)
      if (resp.status === "submitted") {
        // Code written to DB — scraper will pick it up. Keep polling.
        this.startPolling()
      } else {
        this.showState("failed", resp.message || "Submission failed")
      }
    } catch (err) {
      console.error(`[credential-validator] submitCode error:`, err)
      this.showState("failed", err.message || "Request failed")
    }
  }

  handleCodeKeydown(event) {
    if (event.key === "Enter") {
      event.preventDefault()
      this.submitCode(event)
    }
  }

  // ── Polling ──────────────────────────────────────────────────────
  startPolling() {
    if (this.polling) return
    this.polling = true
    this.poll()
  }

  stopPolling() {
    this.polling = false
  }

  async poll() {
    if (!this.polling) return

    try {
      const data = await this.getJSON(this.statusUrlValue)
      this.handlePollResult(data)
    } catch (err) {
      // Network error — just retry
    }

    if (this.polling) {
      setTimeout(() => this.poll(), 2000)
    }
  }

  handlePollResult(data) {
    const cred = data.credential
    const tfa = data.two_fa_request
    console.log(`[credential-validator] poll result: cred=${cred.status}, tfa=${tfa ? tfa.status : 'none'}, currentState=${this.currentState}`)

    // When there's an active 2FA request, always handle it first —
    // the credential may still be "active" while the background job waits for a code
    if (tfa) {
      if (tfa.status === "pending") {
        // Scraper is waiting for user code
        this.showState("awaiting_code", null, tfa)
      } else if (tfa.status === "submitted") {
        // Code submitted, scraper is verifying
        this.showState("verifying")
      } else if (tfa.status === "verified") {
        this.stopPolling()
        this.showState("success")
      } else if (tfa.status === "failed" || tfa.status === "expired") {
        // Check if a new request replaced this one (retry flow)
        // Keep polling — the scraper may create a new request
      }
      return
    }

    // No active 2FA request — check credential status
    if (cred.importing) {
      // Server says import is in progress — track that we've seen it
      this._serverConfirmedImporting = true

      // Show progress if available (e.g. "Importing 42%" or "Searching catalog...")
      if (cred.import_total > 0 && cred.import_progress > 0) {
        const pct = Math.round((cred.import_progress / cred.import_total) * 100)
        this.showState("importing", `Importing ${pct}%`)
      } else if (cred.import_status_text) {
        this.showState("importing", cred.import_status_text)
      } else {
        this.showState("importing")
      }
      return
    }

    if (cred.status === "active") {
      // If we're in "importing" state but server hasn't confirmed importing yet,
      // the job may not have started — keep polling a few more cycles
      if (this.currentState === "importing" && !this._serverConfirmedImporting) {
        this.importPollCount = (this.importPollCount || 0) + 1
        if (this.importPollCount < 5) {
          // Keep showing importing state — job may not have picked up yet
          return
        }
      }

      // Import is truly finished (or was never started)
      this._serverConfirmedImporting = false
      this.stopPolling()
      this.showState("success")
      return
    }

    if (cred.status === "failed") {
      this._serverConfirmedImporting = false
      this.stopPolling()
      this.showState("failed", cred.last_error || "Validation failed")
      return
    }

    // Credential is pending — scraper is still logging in
    if (this.currentState !== "importing") {
      this.showState("validating")
    }
  }

  // ── UI State Machine ─────────────────────────────────────────────
  showState(state, message, tfa) {
    const prevState = this.currentState
    this.currentState = state
    console.log(`[credential-validator] showState: ${prevState} → ${state}`, message || "", tfa || "")

    // Hide everything first — unless staying in the same state
    // (avoid resetting the code input while user is typing)
    if (state !== prevState) {
      this.hideError()
      if (state !== "awaiting_code" && state !== "verifying") {
        this.hideTfaBlock()
      }
      this.enableValidateBtn()
    }

    // Hide import button during non-active states
    this.hideImportBtn()

    switch (state) {
      case "importing":
        this.updateBadge(message || "Importing...", "bg-blue-100 text-blue-800")
        this.disableValidateBtn(message || "Importing...")
        this.showImportBtn()
        this.disableImportBtn(message)
        break

      case "validating":
        this.updateBadge("Validating...", "bg-blue-100 text-blue-800")
        this.disableValidateBtn("Validating...")
        break

      case "awaiting_code":
        this.updateBadge("Awaiting Code", "bg-amber-100 text-amber-800")
        this.disableValidateBtn("Waiting for code...")
        // Only initialize the 2FA form if we weren't already showing it
        if (prevState !== "awaiting_code") {
          this.showTfaBlock(tfa)
        } else {
          // Just update the timer if needed, don't clear the input
          this.updateTfaTimer(tfa)
        }
        break

      case "verifying":
        this.updateBadge("Verifying...", "bg-blue-100 text-blue-800")
        this.disableValidateBtn("Verifying...")
        this.showTfaVerifying()
        break

      case "success":
        this.updateBadge("Active", "bg-green-100 text-green-800")
        this.hideTfaBlock()
        this.enableValidateBtn()
        this.showImportBtn()
        this.enableImportBtn()
        this.showSuccessFlash()
        break

      case "failed":
        this.updateBadge("Failed", "bg-red-100 text-red-800")
        this.hideTfaBlock()
        this.enableValidateBtn()
        if (message) this.showError(message)
        break
    }
  }

  // ── Badge ────────────────────────────────────────────────────────
  updateBadge(text, classes) {
    if (!this.hasStatusBadgeTarget) return
    const badge = this.statusBadgeTarget
    // Remove all bg-* and text-* classes
    badge.className = badge.className.replace(/bg-\S+|text-\S+/g, "").trim()
    badge.classList.add(...classes.split(" "),
      "inline-flex", "items-center", "px-2", "py-0.5",
      "rounded-full", "text-xs", "font-medium")
    badge.textContent = text
  }

  // ── Error block ──────────────────────────────────────────────────
  showError(msg) {
    if (!this.hasErrorBlockTarget) return
    this.errorBlockTarget.classList.remove("hidden")
    if (this.hasErrorTextTarget) this.errorTextTarget.textContent = msg
  }

  hideError() {
    if (this.hasErrorBlockTarget) this.errorBlockTarget.classList.add("hidden")
  }

  // ── Validate button ──────────────────────────────────────────────
  disableValidateBtn(label) {
    if (!this.hasValidateBtnTarget) return
    this.validateBtnTarget.disabled = true
    this.validateBtnTarget.style.opacity = "0.6"
    this.validateBtnTarget.style.pointerEvents = "none"
    if (label) {
      this._origBtnHTML = this._origBtnHTML || this.validateBtnTarget.innerHTML
      this.validateBtnTarget.innerHTML = `
        <svg class="animate-spin w-4 h-4 mr-1" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
        </svg>
        ${label}
      `
    }
  }

  enableValidateBtn() {
    if (!this.hasValidateBtnTarget) return
    this.validateBtnTarget.disabled = false
    this.validateBtnTarget.style.opacity = ""
    this.validateBtnTarget.style.pointerEvents = ""
    if (this._origBtnHTML) {
      this.validateBtnTarget.innerHTML = this._origBtnHTML
    }
  }

  // ── Import Products button ───────────────────────────────────────
  showImportBtn() {
    if (this.hasImportBtnTarget) {
      this.importBtnTarget.classList.remove("hidden")
    }
  }

  hideImportBtn() {
    if (this.hasImportBtnTarget) {
      this.importBtnTarget.classList.add("hidden")
    }
  }

  disableImportBtn(label) {
    if (!this.hasImportBtnTarget) return
    const btn = this.importBtnTarget.querySelector("button")
    if (!btn) return
    btn.disabled = true
    this._origImportBtnHTML = this._origImportBtnHTML || btn.innerHTML
    btn.innerHTML = `
      <svg class="animate-spin w-4 h-4 mr-1" fill="none" viewBox="0 0 24 24">
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
      </svg>
      ${label || "Importing..."}
    `
  }

  enableImportBtn() {
    if (!this.hasImportBtnTarget) return
    const btn = this.importBtnTarget.querySelector("button")
    if (!btn) return
    btn.disabled = false
    if (this._origImportBtnHTML) {
      btn.innerHTML = this._origImportBtnHTML
    }
  }

  // ── 2FA block ────────────────────────────────────────────────────
  showTfaBlock(tfa) {
    console.log(`[credential-validator] showTfaBlock called, hasTfaBlockTarget=${this.hasTfaBlockTarget}`, tfa)
    if (!this.hasTfaBlockTarget) return
    this.tfaBlockTarget.classList.remove("hidden")
    console.log(`[credential-validator] tfaBlock hidden class removed, classList:`, this.tfaBlockTarget.classList.toString())

    if (tfa && this.hasTfaPromptTarget) {
      this.tfaPromptTarget.textContent = tfa.prompt_message || "A verification code has been sent."
    }

    if (this.hasTfaSubmitBtnTarget) {
      this.tfaSubmitBtnTarget.disabled = false
      this._origTfaBtnHTML = this._origTfaBtnHTML || this.tfaSubmitBtnTarget.innerHTML
      this.tfaSubmitBtnTarget.innerHTML = this._origTfaBtnHTML
    }

    if (this.hasTfaCodeInputTarget) {
      this.tfaCodeInputTarget.disabled = false
      this.tfaCodeInputTarget.value = ""
      this.tfaCodeInputTarget.focus()
    }

    if (this.hasTfaMessageTarget) {
      this.tfaMessageTarget.textContent = ""
    }

    // Start countdown timer
    if (tfa && tfa.expires_at) {
      this.startTimer(tfa.expires_at)
    }
  }

  showTfaVerifying() {
    if (!this.hasTfaBlockTarget) return
    this.tfaBlockTarget.classList.remove("hidden")

    if (this.hasTfaSubmitBtnTarget) {
      this.tfaSubmitBtnTarget.disabled = true
      this.tfaSubmitBtnTarget.innerHTML = `
        <svg class="animate-spin w-4 h-4 mr-1.5" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
        </svg>
        Verifying...
      `
    }
    if (this.hasTfaCodeInputTarget) {
      this.tfaCodeInputTarget.disabled = true
    }
    if (this.hasTfaMessageTarget) {
      this.tfaMessageTarget.textContent = "Your code has been submitted. Verifying now..."
    }
  }

  // Update just the timer without resetting the form (for repeated poll results)
  updateTfaTimer(tfa) {
    if (tfa && tfa.expires_at) {
      this.startTimer(tfa.expires_at)
    }
  }

  hideTfaBlock() {
    if (this.hasTfaBlockTarget) this.tfaBlockTarget.classList.add("hidden")
    this.stopTimer()
  }

  // ── Timer ────────────────────────────────────────────────────────
  startTimer(expiresAt) {
    this.stopTimer()
    const expiry = new Date(expiresAt)

    const tick = () => {
      const remaining = Math.max(0, Math.floor((expiry - new Date()) / 1000))
      if (!this.hasTfaTimerTarget) return

      if (remaining <= 0) {
        this.tfaTimerTarget.textContent = "Expired"
        this.stopTimer()
        return
      }
      const m = Math.floor(remaining / 60)
      const s = remaining % 60
      this.tfaTimerTarget.textContent = `${m}:${s.toString().padStart(2, "0")}`
    }

    tick()
    this.timerInterval = setInterval(tick, 1000)
  }

  stopTimer() {
    if (this.timerInterval) {
      clearInterval(this.timerInterval)
      this.timerInterval = null
    }
  }

  // ── Success flash ────────────────────────────────────────────────
  showSuccessFlash() {
    // Insert a temporary green flash at top of page
    const flash = document.createElement("div")
    flash.className = "fixed top-4 right-4 z-50 bg-green-50 border border-green-300 text-green-800 px-4 py-3 rounded-lg shadow-lg text-sm font-medium flex items-center gap-2"
    flash.innerHTML = `
      <svg class="w-5 h-5 text-green-500" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
        <path stroke-linecap="round" stroke-linejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
      </svg>
      Credentials verified successfully!
    `
    document.body.appendChild(flash)
    setTimeout(() => flash.remove(), 5000)
  }

  // ── Already active flash ────────────────────────────────────────
  showAlreadyActiveFlash(message) {
    const flash = document.createElement("div")
    flash.className = "fixed top-4 right-4 z-50 bg-blue-50 border border-blue-300 text-blue-800 px-4 py-3 rounded-lg shadow-lg text-sm font-medium flex items-center gap-2"
    flash.innerHTML = `
      <svg class="w-5 h-5 text-blue-500" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
        <path stroke-linecap="round" stroke-linejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
      </svg>
      ${message || "You are already validated for this supplier."}
    `
    document.body.appendChild(flash)
    setTimeout(() => flash.remove(), 5000)
  }

  // ── Fetch helpers ────────────────────────────────────────────────
  async postJSON(url, body = {}) {
    const resp = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": this.csrfToken,
      },
      body: JSON.stringify(body),
    })
    if (!resp.ok) {
      const data = await resp.json().catch(() => ({}))
      throw new Error(data.message || `HTTP ${resp.status}`)
    }
    return resp.json()
  }

  async getJSON(url) {
    const resp = await fetch(url, {
      headers: { "Accept": "application/json" },
    })
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`)
    return resp.json()
  }

  get csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }
}
