import { Controller } from "@hotwired/stimulus"

// One-shot mover, appended by confirm.turbo_stream.erb.
//
// Confirming a match has to relocate its card to the Confirmed section at the
// foot of the page. Re-rendering the card server-side would mean rebuilding the
// whole teaser-column set for the list just to redraw one row, so instead we
// move the node that's already on the page — every supplier column stays
// exactly as rendered. Stimulus connects on insertion, so no inline script.
export default class extends Controller {
  static values = { matchId: String, count: Number }

  connect() {
    const card = document.getElementById(this.matchIdValue)
    const shelf = document.getElementById("confirmed-matches-container")
    const header = document.getElementById("confirmed-matches-header")
    const count = document.getElementById("confirmed-matches-count")

    // The card is leaving a category section, so that section's own tally has
    // to come down with it — and the section itself goes if it's now empty.
    const origin = card && card.closest("[data-match-filter-target='categoryGroup']")

    if (card && shelf) shelf.appendChild(card)
    if (header) header.classList.remove("hidden")
    if (count && this.hasCountValue) count.textContent = this.countValue

    if (origin && origin.id !== "confirmed-matches-section") {
      const originCount = origin.querySelector("[data-category-count]")
      if (originCount) {
        originCount.textContent = Math.max(0, (parseInt(originCount.textContent, 10) || 0) - 1)
      }
      if (origin.querySelectorAll("[data-match-filter-target='row']").length === 0) {
        origin.classList.add("hidden")
      }
    }

    // Nothing left to do — don't leave a marker div in the list.
    this.element.remove()
  }
}
