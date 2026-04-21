import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["modal", "category", "message", "files", "fileLabel", "submitBtn", "error"]

  connect() {
    this._handleKeydown = (e) => {
      if (e.key === "Escape") this.close()
    }
    this._handleOpen = () => this.open()
    window.addEventListener("feedback:open", this._handleOpen)
  }

  disconnect() {
    window.removeEventListener("feedback:open", this._handleOpen)
    document.removeEventListener("keydown", this._handleKeydown)
    document.body.style.overflow = ""
  }

  open() {
    this.modalTarget.classList.remove("hidden")
    document.addEventListener("keydown", this._handleKeydown)
    document.body.style.overflow = "hidden"
  }

  close() {
    this.modalTarget.classList.add("hidden")
    document.removeEventListener("keydown", this._handleKeydown)
    document.body.style.overflow = ""
    this.resetForm()
  }

  closeBackdrop(event) {
    if (event.target === event.currentTarget) this.close()
  }

  updateFileLabel() {
    const files = this.filesTarget.files
    if (files.length === 0) {
      this.fileLabelTarget.textContent = "No files selected"
    } else if (files.length === 1) {
      this.fileLabelTarget.textContent = files[0].name
    } else {
      this.fileLabelTarget.textContent = `${files.length} files selected`
    }
  }

  async submit(event) {
    event.preventDefault()
    this.hideError()

    const category = this.categoryTarget.value
    const message = this.messageTarget.value.trim()

    if (!message) {
      this.showError("Please describe the issue or feature request.")
      return
    }

    this.submitBtnTarget.disabled = true
    this.submitBtnTarget.textContent = "Sending..."

    const formData = new FormData()
    formData.append("feedback[category]", category)
    formData.append("feedback[message]", message)

    const files = this.filesTarget.files
    for (let i = 0; i < files.length; i++) {
      formData.append("feedback[attachments][]", files[i])
    }

    try {
      const response = await fetch("/feedback", {
        method: "POST",
        headers: {
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]').content,
          "Accept": "application/json"
        },
        body: formData
      })

      const data = await response.json()

      if (response.ok) {
        this.close()
        this.showFlash("Feedback sent! Thank you for helping us improve.")
      } else {
        this.showError(data.error || "Something went wrong. Please try again.")
      }
    } catch (error) {
      this.showError("Network error. Please try again.")
    } finally {
      this.submitBtnTarget.disabled = false
      this.submitBtnTarget.textContent = "Send Feedback"
    }
  }

  showError(message) {
    this.errorTarget.textContent = message
    this.errorTarget.classList.remove("hidden")
  }

  hideError() {
    this.errorTarget.classList.add("hidden")
  }

  resetForm() {
    this.categoryTarget.value = "bug"
    this.messageTarget.value = ""
    this.filesTarget.value = ""
    this.fileLabelTarget.textContent = "No files selected"
    this.hideError()
    this.submitBtnTarget.disabled = false
    this.submitBtnTarget.textContent = "Send Feedback"
  }

  showFlash(message) {
    const flash = document.createElement("div")
    flash.className = "fixed top-4 right-4 z-[60] max-w-sm bg-green-50 border border-green-200 rounded-lg p-4 shadow-lg"
    flash.setAttribute("data-controller", "flash")
    flash.innerHTML = `
      <div class="flex items-start">
        <svg class="w-5 h-5 text-green-400 mt-0.5 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20">
          <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.857-9.809a.75.75 0 00-1.214-.882l-3.483 4.79-1.88-1.88a.75.75 0 10-1.06 1.061l2.5 2.5a.75.75 0 001.137-.089l4-5.5z" clip-rule="evenodd"/>
        </svg>
        <p class="ml-3 text-sm font-medium text-green-800">${message}</p>
      </div>
    `
    document.body.appendChild(flash)
    setTimeout(() => flash.remove(), 5000)
  }
}
