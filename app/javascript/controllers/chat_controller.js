import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["messageList", "input", "form", "submitBtn", "welcome", "charCount"]
  static values = { eventPlanId: Number, maxLength: { type: Number, default: 2000 } }

  connect() {
    this.scrollToBottom()

    // Watch for new messages added by Turbo Streams and auto-scroll
    this.observer = new MutationObserver(() => this.scrollToBottom())
    if (this.hasMessageListTarget) {
      this.observer.observe(this.messageListTarget, { childList: true, subtree: true })
    }
  }

  disconnect() {
    this.observer?.disconnect()
  }

  updateCharCount() {
    if (!this.hasCharCountTarget) return
    const len = this.inputTarget.value.length
    const max = this.maxLengthValue
    if (len === 0) {
      this.charCountTarget.textContent = ""
    } else {
      this.charCountTarget.textContent = `${len} / ${max}`
      this.charCountTarget.classList.toggle("text-red-500", len >= max)
      this.charCountTarget.classList.toggle("dark:text-red-400", len >= max)
      this.charCountTarget.classList.toggle("text-gray-400", len < max)
      this.charCountTarget.classList.toggle("dark:text-gray-500", len < max)
    }
  }

  submit(event) {
    event.preventDefault()

    const content = this.inputTarget.value.trim()
    if (!content) return

    if (content.length > this.maxLengthValue) {
      alert(`Message is too long (${content.length} characters). Please keep it under ${this.maxLengthValue} characters.`)
      return
    }

    this.submitBtnTarget.disabled = true
    this.inputTarget.value = ""
    this.inputTarget.style.height = "auto"
    this.updateCharCount()

    const url = `/menu-planner/${this.eventPlanIdValue}/messages`
    const token = this.formTarget.querySelector("input[name='authenticity_token']").value

    fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "text/vnd.turbo-stream.html",
        "X-CSRF-Token": token,
      },
      body: `content=${encodeURIComponent(content)}`,
    })
      .then((response) => {
        if (!response.ok) throw new Error("Failed to send message")
        return response.text()
      })
      .then((html) => {
        Turbo.renderStreamMessage(html)
        this.submitBtnTarget.disabled = false
        this.inputTarget.focus()
      })
      .catch((error) => {
        console.error("Chat error:", error)
        this.submitBtnTarget.disabled = false
        this.inputTarget.value = content
      })
  }

  keydown(event) {
    // Submit on Enter (without Shift for newlines)
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      this.formTarget.requestSubmit()
    }
  }

  scrollToBottom() {
    if (this.hasMessageListTarget) {
      this.messageListTarget.scrollTop = this.messageListTarget.scrollHeight
    }
  }
}
