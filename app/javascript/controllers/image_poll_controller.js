import { Controller } from "@hotwired/stimulus"

// Swaps product-thumbnail placeholders for their real R2 image the moment the
// async mirror job finishes — so the chef doesn't have to close and reopen the
// matching modal to see the picture. Watches every <img data-product-thumb-id>
// that is still a placeholder, polls /product_images/resolve, and swaps the src
// (and any other img for the same product) in place. Stops once nothing is
// pending or after a fixed number of attempts.
export default class extends Controller {
  static values = {
    interval: { type: Number, default: 1500 },
    maxAttempts: { type: Number, default: 10 }
  }

  connect() {
    this.attempts = 0
    this.markPending(true)
    if (this.pendingIds().length > 0) this.scheduleNext()
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }

  placeholderImgs() {
    return Array.from(this.element.querySelectorAll("img[data-product-thumb-id]"))
      .filter((img) => img.src.startsWith("data:") && img.dataset.productThumbId)
  }

  pendingIds() {
    return [...new Set(this.placeholderImgs().map((img) => img.dataset.productThumbId))]
  }

  // A subtle pulse tells the chef an image is on its way.
  markPending(on) {
    this.placeholderImgs().forEach((img) => img.classList.toggle("animate-pulse", on))
  }

  scheduleNext() {
    if (this.attempts >= this.maxAttemptsValue) {
      this.markPending(false) // give up — these aren't coming
      return
    }
    this.timer = setTimeout(() => this.poll(), this.intervalValue)
  }

  async poll() {
    this.attempts++
    const ids = this.pendingIds()
    if (ids.length === 0) return

    try {
      const resp = await fetch(`/product_images/resolve?ids=${ids.join(",")}`, {
        headers: { Accept: "application/json" }
      })
      if (resp.ok) {
        const map = await resp.json()
        Object.entries(map).forEach(([id, url]) => this.swap(id, url))
      }
    } catch (_e) {
      // network blip — just try again next tick
    }

    if (this.pendingIds().length > 0) {
      this.scheduleNext()
    } else {
      this.markPending(false)
    }
  }

  swap(id, url) {
    this.element
      .querySelectorAll(`img[data-product-thumb-id="${id}"]`)
      .forEach((img) => {
        img.classList.remove("animate-pulse")
        img.src = url
      })
  }
}
