import { Controller } from "@hotwired/stimulus"

// Mobile cart/review page. Delivery date edits PATCH the order (same JSON
// endpoint the desktop review uses); Place submits the existing submit_batch
// form. Keeps a celebratory confetti burst on placement.
export default class extends Controller {
  static targets = ["deliveryDate", "placeButton"]

  connect() {
    this.updatePlaceState()
  }

  updateDeliveryDate(event) {
    const input = event.currentTarget
    fetch(`/orders/${input.dataset.orderId}`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content,
        "Accept": "application/json"
      },
      body: JSON.stringify({ order: { delivery_date: input.value } })
    })
    input.classList.remove("ring-2", "ring-amber-400")
    this.updatePlaceState()
  }

  updatePlaceState() {
    if (!this.hasPlaceButtonTarget) return
    const missing = this.deliveryDateTargets.some(i => !i.value)
    const blockedByMinimum = this.placeButtonTarget.dataset.minimumsMet !== "true"
    this.placeButtonTarget.disabled = missing || blockedByMinimum
  }

  place(event) {
    this.confetti(event.currentTarget)
  }

  confetti(fromEl, count = 22) {
    const rect = fromEl.getBoundingClientRect()
    const cx = rect.left + rect.width / 2, cy = rect.top + rect.height / 2
    const colors = ["#16A34A", "#4A7C59", "#D4943A", "#FACC15", "#60A5FA"]
    for (let i = 0; i < count; i++) {
      const p = document.createElement("div")
      const size = 6 + (i % 3) * 3
      p.style.cssText = `position:fixed;left:${cx}px;top:${cy}px;width:${size}px;height:${size * (i % 2 ? 1 : 0.6)}px;` +
        `background:${colors[i % colors.length]};z-index:89;pointer-events:none;` +
        `border-radius:${i % 2 ? "50%" : "2px"};opacity:1;will-change:transform,opacity;`
      document.body.appendChild(p)
      const angle = (Math.PI * 2 * i) / count + Math.random() * 0.5
      const vx = Math.cos(angle) * (50 + Math.random() * 70)
      const launch = -(38 + Math.random() * 55)
      const fall = 110 + Math.random() * 80
      const rot = (Math.random() - 0.5) * 720
      const dur = 1400 + Math.random() * 400
      p.animate([
        { transform: "translate(0,0) rotate(0deg)", opacity: 1 },
        { transform: `translate(${vx * 0.55}px, ${launch}px) rotate(${rot * 0.4}deg)`, opacity: 1, offset: 0.3, easing: "cubic-bezier(.2,.9,.5,1)" },
        { transform: `translate(${vx}px, ${fall}px) rotate(${rot}deg)`, opacity: 0 },
      ], { duration: dur, easing: "linear", fill: "forwards" })
      setTimeout(() => p.remove(), dur + 50)
    }
  }
}
