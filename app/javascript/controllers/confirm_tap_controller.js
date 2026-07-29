import { Controller } from "@hotwired/stimulus"

// Two-tap confirmation without native dialogs. Android Chrome offers a
// "suppress dialogs" checkbox on window.confirm — one accidental tap and
// every confirmation in the app silently stops working. Instead: the first
// tap arms the button ("Tap again to confirm", red), a second tap within
// the window proceeds, and it disarms itself after a few seconds.
//
// Usage on a button_to form:
//   form: { data: { controller: "confirm-tap",
//                   action: "submit->confirm-tap#intercept",
//                   confirm_tap_message_value: "Tap again to cancel" } }
export default class extends Controller {
  static values = {
    message: { type: String, default: "Tap again to confirm" },
    timeout: { type: Number, default: 3500 }
  }

  intercept(event) {
    if (this.armed) {
      this.disarm()
      return // let the submit through
    }
    event.preventDefault()
    this.arm()
  }

  arm() {
    this.armed = true
    const btn = this.button
    if (btn) {
      this.originalHtml = btn.innerHTML
      this.originalClass = btn.className
      btn.innerHTML = this.messageValue
      btn.classList.add("bg-red-600", "text-white")
    }
    this.timer = setTimeout(() => this.disarm(), this.timeoutValue)
  }

  disarm() {
    clearTimeout(this.timer)
    this.armed = false
    const btn = this.button
    if (btn && this.originalHtml != null) {
      btn.innerHTML = this.originalHtml
      btn.className = this.originalClass
    }
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  get button() {
    return this.element.tagName === "FORM" ? this.element.querySelector("button") : this.element
  }
}
