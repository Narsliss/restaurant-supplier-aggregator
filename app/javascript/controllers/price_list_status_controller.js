import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }
  static targets = ["title"]

  connect() {
    this.poll()
  }

  disconnect() {
    if (this.timeout) clearTimeout(this.timeout)
  }

  async poll() {
    try {
      const response = await fetch(this.urlValue)
      const data = await response.json()

      if (data.status === "parsed" && data.redirect_to) {
        window.location.href = data.redirect_to
        return
      }

      if (data.status === "failed") {
        this.titleTarget.textContent = "Parsing failed"
        this.element.classList.remove("bg-blue-50", "border-blue-200")
        this.element.classList.add("bg-red-50", "border-red-200")
        this.titleTarget.classList.remove("text-blue-800")
        this.titleTarget.classList.add("text-red-800")
        if (data.error_message) {
          this.titleTarget.textContent = `Failed: ${data.error_message}`
        }
        return
      }

      // Keep polling
      this.timeout = setTimeout(() => this.poll(), 3000)
    } catch (error) {
      // Retry on network error
      this.timeout = setTimeout(() => this.poll(), 5000)
    }
  }
}
