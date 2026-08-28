import { Controller } from "@hotwired/stimulus"

// Live preview for Set Weight.
//
// The point of it is the consequence, not the arithmetic: a chef sees the price
// their number produces sitting next to what the other suppliers charge, and
// which supplier it crowns, BEFORE they save. That is the only thing that
// catches a decimal-point slip, because a plausibility rail cannot — typing 2.8
// for 28 yields $11.43/lb, an ordinary foodservice price.
export default class extends Controller {
  static targets = ["weight", "unit", "basis", "preview", "verdict"]
  static values = {
    price: Number,
    pieceCount: Number,
    supplier: String,
    // [{ name, perLb }] for the other suppliers already on this line
    peers: Array
  }

  connect() {
    this.render()
  }

  render() {
    const weight = parseFloat(this.weightTarget.value)
    if (!(weight > 0)) return this.clear()

    const totalOz = this.totalOunces(weight)
    if (!(totalOz > 0)) return this.clear()

    const perLb = this.priceValue / (totalOz / 16)
    if (!isFinite(perLb) || perLb <= 0) return this.clear()

    this.previewTarget.textContent =
      `${this.money(this.priceValue)} ÷ ${this.round(totalOz / 16)} lb = ${this.money(perLb)}/lb`

    this.verdictTarget.textContent = this.verdictFor(perLb)
  }

  clear() {
    this.previewTarget.textContent = ""
    this.verdictTarget.textContent = ""
  }

  totalOunces(weight) {
    const oz = weight * this.unitFactor()
    if (this.basisValue() !== "per_piece") return oz
    return this.pieceCountValue > 0 ? oz * this.pieceCountValue : 0
  }

  unitFactor() {
    switch (this.hasUnitTarget ? this.unitTarget.value : "lb") {
      case "oz": return 1
      case "kg": return 35.274
      default: return 16
    }
  }

  basisValue() {
    return this.hasBasisTarget ? this.basisTarget.value : "per_pack"
  }

  // Names the supplier this weight would make cheapest, so the chef sees what
  // their number decides rather than only what it computes.
  verdictFor(perLb) {
    const peers = (this.peersValue || []).filter(p => p.perLb > 0)
    if (peers.length === 0) return ""

    const listed = peers.map(p => `${p.name} ${this.money(p.perLb)}/lb`).join(" · ")
    const cheapestPeer = peers.reduce((a, b) => (a.perLb <= b.perLb ? a : b))

    const winner = perLb <= cheapestPeer.perLb ? this.supplierValue : cheapestPeer.name
    return `${listed} — this would make ${winner} cheapest.`
  }

  money(n) {
    return `$${n.toFixed(2)}`
  }

  round(n) {
    return Math.round(n * 100) / 100
  }
}
