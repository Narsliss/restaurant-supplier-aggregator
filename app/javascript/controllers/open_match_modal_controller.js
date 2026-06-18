import { Controller } from "@hotwired/stimulus"

// Click a match row's left cell to open the matching modal by pointing the
// #match_modal Turbo Frame at the edit URL. Clicks on [data-modal-ignore]
// elements (e.g. the remove button) are ignored.
export default class extends Controller {
  static values = { url: String }

  open(event) {
    if (event.target.closest("[data-modal-ignore]")) return
    const frame = document.getElementById("match_modal")
    if (frame) frame.src = this.urlValue
  }
}
