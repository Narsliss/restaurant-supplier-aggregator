import { Controller } from "@hotwired/stimulus"
import { openCalendar, dateLabel } from "controllers/mobile_calendar"

// Safari only (Safari audit, Oct 21 2026). Safari — and every iPhone/iPad
// browser, which all run Safari's engine — draws <input type="date"> with no
// calendar icon, shows TODAY in an empty field, and opens its picker downward
// even from the builder's bottom bar, where it lands off-screen. In Safari this
// swaps the field for a button that opens the month calendar the phone flow
// already uses. Every other browser returns on the first line of connect() and
// keeps the native field untouched.
//
// The input stays in the page (hidden) and keeps its name, value and
// listeners: picking a date sets input.value and fires the same input/change
// events a native pick would, so the form post and the builder/review/order
// JS that read it are unchanged.
const BUTTON_ATTR = "data-safari-date-button"
const DISPLAY_CLASSES = new Set(["block", "inline-block", "flex", "inline-flex", "hidden"])

function isSafariEngine() {
  return navigator.vendor === "Apple Computer, Inc."
}

export default class extends Controller {
  connect() {
    if (!isSafariEngine()) return
    this.enhanced = true
    const input = this.element

    // The builder clones its bottom bar (cloneNode), which copies a button made
    // for the original. Drop that dead copy and make one wired to this input.
    if (input.nextElementSibling?.hasAttribute(BUTTON_ATTR)) input.nextElementSibling.remove()

    this.button = document.createElement("button")
    this.button.type = "button"
    this.button.setAttribute(BUTTON_ATTR, "")
    this.button.setAttribute("aria-label", "Delivery date")
    this.button.addEventListener("click", () => this.open())
    input.insertAdjacentElement("afterend", this.button)
    input.classList.add("hidden")

    // Other code sets input.value directly (the builder syncs its bar copies
    // that way) without firing events; keep the button's label in step.
    const native = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")
    const render = () => this.render()
    Object.defineProperty(input, "value", {
      configurable: true,
      get() { return native.get.call(this) },
      set(v) { native.set.call(this, v); render() }
    })

    // Mirror the input's classes (width, border, the builder's orange
    // "pick a date" ring) so the button looks and highlights like the field.
    this.observer = new MutationObserver(() => this.render())
    this.observer.observe(input, { attributes: true, attributeFilter: ["class"] })
    this.render()
  }

  disconnect() {
    if (!this.enhanced) return
    this.observer?.disconnect()
    delete this.element.value
    this.element.classList.remove("hidden")
    this.button?.remove()
  }

  open() {
    const input = this.element
    openCalendar(input.value || null, iso => {
      input.value = iso
      input.dispatchEvent(new Event("input", { bubbles: true }))
      input.dispatchEvent(new Event("change", { bubbles: true }))
    }, { maxIso: input.max || null, narrow: true })
  }

  render() {
    const input = this.element
    const mirrored = input.className.split(/\s+/).filter(c => c && !DISPLAY_CLASSES.has(c))
    const wide = input.className.split(/\s+/).some(c => c === "block" || c === "w-full")
    this.button.className = [
      ...mirrored, wide ? "flex" : "inline-flex",
      "items-center justify-between gap-2 border px-2 py-1 bg-white text-left whitespace-nowrap cursor-pointer"
    ].join(" ")
    const value = input.value
    this.button.innerHTML = `
      <span class="${value ? "text-gray-900" : "text-gray-500"}">${value ? dateLabel(value) : "Pick a date"}</span>
      <svg class="w-4 h-4 text-gray-400 shrink-0" fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24" aria-hidden="true">
        <path stroke-linecap="round" stroke-linejoin="round" d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"/>
      </svg>`
  }
}
