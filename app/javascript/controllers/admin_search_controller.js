import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form"]

  search() {
    clearTimeout(this._timer)
    this._timer = setTimeout(() => {
      this.formTarget.requestSubmit()
    }, 300)
  }

  disconnect() {
    clearTimeout(this._timer)
  }
}
