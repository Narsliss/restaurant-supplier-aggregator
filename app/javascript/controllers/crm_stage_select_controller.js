import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }

  async change(event) {
    const newStage = event.target.value
    if (!newStage) return

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          "Accept": "text/html"
        },
        body: JSON.stringify({ pipeline_stage: newStage })
      })

      if (response.ok) {
        window.location.reload()
      }
    } catch {
      window.location.reload()
    }
  }
}
