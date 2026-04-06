import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }

  async complete(event) {
    event.preventDefault()
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

    try {
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "X-CSRF-Token": csrfToken,
          "Accept": "application/json"
        }
      })

      if (response.ok) {
        // Strike through and fade the task
        this.element.classList.add("opacity-50", "line-through")
        const checkbox = this.element.querySelector("input[type='checkbox']")
        if (checkbox) checkbox.checked = true
        if (checkbox) checkbox.disabled = true
      }
    } catch {
      // Fallback: submit normally
      window.location.reload()
    }
  }
}
