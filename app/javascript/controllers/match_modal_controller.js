import { Controller } from "@hotwired/stimulus"

// Drives the matching modal loaded into the #match_modal Turbo Frame.
// Closing clears the frame (which removes the overlay).
export default class extends Controller {
  connect() {
    this._esc = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("keydown", this._esc)
    document.body.style.overflow = "hidden"
  }

  disconnect() {
    document.removeEventListener("keydown", this._esc)
    document.body.style.overflow = ""
  }

  close(event) {
    if (event) event.preventDefault()
    const frame = document.getElementById("match_modal")
    if (frame) frame.innerHTML = ""
  }

  // Backdrop click closes; clicks inside the panel are stopped in the markup.
  backdrop(event) {
    if (event.target === event.currentTarget) this.close(event)
  }
}
