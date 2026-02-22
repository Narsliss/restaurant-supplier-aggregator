import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    dismissAfter: { type: Number, default: 0 }
  }

  static targets = ["progress"]

  connect() {
    if (this.dismissAfterValue > 0) {
      this._startProgressBar()

      this.timeout = setTimeout(() => {
        this.dismiss()
      }, this.dismissAfterValue)
    }
  }

  disconnect() {
    if (this.timeout) clearTimeout(this.timeout)
    if (this._animFrame) cancelAnimationFrame(this._animFrame)
  }

  dismiss() {
    if (this._animFrame) cancelAnimationFrame(this._animFrame)

    // Slide up and fade out
    this.element.style.transition = "transform 0.3s ease-in, opacity 0.3s ease-in"
    this.element.style.transform = "translate(-50%, -100%)"
    this.element.style.opacity = "0"

    setTimeout(() => {
      this.element.remove()
    }, 300)
  }

  // Animate the progress bar from 100% to 0% over the dismiss duration
  _startProgressBar() {
    if (!this.hasProgressTarget) return

    const bar = this.progressTarget
    const duration = this.dismissAfterValue
    const startTime = performance.now()

    const tick = (now) => {
      const elapsed = now - startTime
      const remaining = Math.max(0, 1 - elapsed / duration)
      bar.style.width = `${remaining * 100}%`

      if (remaining > 0) {
        this._animFrame = requestAnimationFrame(tick)
      }
    }

    bar.style.width = "100%"
    this._animFrame = requestAnimationFrame(tick)
  }
}
