import { Controller } from "@hotwired/stimulus"

// Handles location switching from the nav dropdown.
// When the user selects a different restaurant, POSTs to /locations/switch
// and reloads the page with the new location context.
export default class extends Controller {
  static targets = ["select"]

  change(event) {
    const locationId = event.target.value
    const token = document.querySelector('meta[name="csrf-token"]')?.content

    fetch("/locations/switch", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": token,
        "Accept": "application/json"
      },
      body: JSON.stringify({ location_id: locationId })
    }).then(response => {
      if (response.ok) {
        // Hard reload to bypass Turbo's snapshot cache, which can show
        // stale nav state when the location context changes.
        window.location.reload()
      }
    })
  }
}
