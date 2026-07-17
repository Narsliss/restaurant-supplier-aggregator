import { Controller } from "@hotwired/stimulus"

// Mobile order builder (Comp A). One selected supplier + qty (+ CS/PC uom) per
// product match — mirroring AggregatedListOrderService's contract exactly.
// On submit, state is serialized into quantities[] / supplier_overrides[] /
// uom_overrides[] hidden fields; the server-side ordering path is unchanged.
export default class extends Controller {
  static targets = ["form", "hiddenFields", "search", "categoryChip", "emptyState", "noResults",
                    "card", "cell", "stepperRow", "qtyDisplay", "uomToggle", "selectedLabel",
                    "lineTotal", "ribbon", "ribbonPills", "ribbonTotal", "deliveryDate", "submitButton"]
  static values = { minimums: Object }

  connect() {
    // state: matchId -> { supplierId, qty, uom }
    this.state = {}
    this.category = "all"
    this.supplierNames = {}
    this.cellTargets.forEach(cell => {
      const card = cell.closest("[data-mobile-order-builder-target=card]")
      this.supplierNames[cell.dataset.supplierId] ||= cell.querySelector("div").textContent.replace(" ★", "").trim()
    })
    // Prefill from server-rendered quantities (returning from review)
    this.cardTargets.forEach(card => {
      const qty = parseInt(card.dataset.initialQty || "0", 10)
      if (qty > 0 && card.dataset.cheapestSupplierId) {
        this.state[card.dataset.matchId] = { supplierId: card.dataset.cheapestSupplierId, qty, uom: "CS" }
        this.renderCard(card)
      }
    })
    this.filter()
    this.refreshRibbon()
  }

  // ---- Filtering (blank search => only in-order items, else empty state) ----

  filter() {
    const q = (this.searchTarget.value || "").trim().toLowerCase()
    const blank = q === "" && this.category === "all"
    let visible = 0
    let inOrderVisible = 0

    this.cardTargets.forEach(card => {
      const inOrder = (this.state[card.dataset.matchId]?.qty || 0) > 0
      let show
      if (blank) {
        show = inOrder
      } else {
        const matchesQuery = q === "" || card.dataset.name.includes(q)
        const matchesCat = this.category === "all" ||
          (this.category === "__frequent__" ? card.dataset.frequent === "true" : card.dataset.category === this.category)
        show = matchesQuery && matchesCat
      }
      card.classList.toggle("hidden", !show)
      if (show) { visible++; if (inOrder) inOrderVisible++ }
    })

    this.emptyStateTarget.classList.toggle("hidden", !(blank && visible === 0))
    this.noResultsTarget.classList.toggle("hidden", blank || visible > 0)
  }

  setCategory(event) {
    this.category = event.currentTarget.dataset.category
    this.categoryChipTargets.forEach(chip => {
      const active = chip.dataset.category === this.category
      chip.classList.toggle("bg-brand-green", active)
      chip.classList.toggle("text-white", active)
      chip.classList.toggle("border-brand-green", active)
      chip.classList.toggle("bg-white", !active)
      chip.classList.toggle("text-gray-600", !active)
      chip.classList.toggle("border-gray-200", !active)
    })
    this.filter()
  }

  // ---- Cell selection / steppers ----

  tapCell(event) {
    const cell = event.currentTarget
    const matchId = cell.dataset.matchId
    const supplierId = cell.dataset.supplierId
    const existing = this.state[matchId]

    if (existing && existing.supplierId === supplierId) {
      existing.qty += 1
    } else {
      // New selection (or switching supplier — qty carries over)
      const qty = existing ? existing.qty : 1
      this.state[matchId] = { supplierId, qty, uom: "CS" }
      if (!existing) this.celebrateIfBest(cell)
    }
    this.renderCard(cell.closest("[data-mobile-order-builder-target=card]"))
    this.refreshRibbon()
  }

  increment(event) { this.bumpQty(event, +1) }
  decrement(event) { this.bumpQty(event, -1) }

  bumpQty(event, delta) {
    const card = event.currentTarget.closest("[data-mobile-order-builder-target=card]")
    const s = this.state[card.dataset.matchId]
    if (!s) return
    s.qty = Math.max(0, s.qty + delta)
    if (s.qty === 0) delete this.state[card.dataset.matchId]
    this.renderCard(card)
    this.refreshRibbon()
    this.filter()
  }

  setUom(event) {
    const card = event.currentTarget.closest("[data-mobile-order-builder-target=card]")
    const s = this.state[card.dataset.matchId]
    if (!s) return
    s.uom = event.currentTarget.dataset.uom
    this.renderCard(card)
    this.refreshRibbon()
  }

  // ---- Rendering ----

  cellFor(card, supplierId) {
    return card.querySelector(`[data-supplier-id="${supplierId}"][data-match-id]`)
  }

  effectivePrice(cell, uom) {
    if (uom === "PC" && cell.dataset.piecePrice) return parseFloat(cell.dataset.piecePrice)
    return parseFloat(cell.dataset.price)
  }

  renderCard(card) {
    const s = this.state[card.dataset.matchId]
    const stepperRow = card.querySelector("[data-mobile-order-builder-target='stepperRow']")

    // Cell highlight
    card.querySelectorAll("button[data-supplier-id]").forEach(cell => {
      const selected = s && cell.dataset.supplierId === s.supplierId
      cell.classList.toggle("ring-2", selected)
      cell.classList.toggle("ring-brand-green", selected)
      cell.classList.toggle("border-brand-green", selected)
    })

    if (!s) {
      stepperRow.classList.add("hidden")
      stepperRow.classList.remove("flex")
      return
    }

    stepperRow.classList.remove("hidden")
    stepperRow.classList.add("flex")
    const cell = this.cellFor(card, s.supplierId)
    card.querySelector("[data-mobile-order-builder-target='qtyDisplay']").textContent = s.qty

    // CS/PC toggle only when the selected supplier offers a piece price
    const uomToggle = card.querySelector("[data-mobile-order-builder-target='uomToggle']")
    if (cell?.dataset.piecePrice) {
      uomToggle.classList.remove("hidden")
      uomToggle.querySelectorAll("button").forEach(btn => {
        const active = btn.dataset.uom === s.uom
        btn.classList.toggle("bg-brand-navy", active)
        btn.classList.toggle("text-white", active)
        btn.classList.toggle("text-gray-500", !active)
      })
    } else {
      uomToggle.classList.add("hidden")
      s.uom = "CS"
    }

    const price = cell ? this.effectivePrice(cell, s.uom) : 0
    card.querySelector("[data-mobile-order-builder-target='selectedLabel']").textContent =
      `${this.supplierNames[s.supplierId] || ""}${s.uom === "PC" ? " · PIECE" : ""}`
    card.querySelector("[data-mobile-order-builder-target='lineTotal']").textContent =
      this.currency(price * s.qty)
  }

  refreshRibbon() {
    const totals = {}
    Object.entries(this.state).forEach(([matchId, s]) => {
      const card = this.cardTargets.find(c => c.dataset.matchId === matchId)
      const cell = card && this.cellFor(card, s.supplierId)
      if (!cell) return
      totals[s.supplierId] = (totals[s.supplierId] || 0) + this.effectivePrice(cell, s.uom) * s.qty
    })

    const supplierIds = Object.keys(totals)
    this.ribbonTarget.classList.toggle("hidden", supplierIds.length === 0)
    if (supplierIds.length === 0) return

    this.ribbonPillsTarget.innerHTML = supplierIds.map(id => {
      const total = totals[id]
      const min = this.minimumsValue[id]
      const met = min == null || total >= min
      const name = this.supplierNames[id] || ""
      return `<div class="shrink-0 rounded-lg px-2.5 py-1.5 border ${met ? "bg-green-500/15 border-green-400/60" : "bg-red-500/15 border-red-400/60"}">
        <div class="flex items-center gap-1.5">
          <span class="text-[11px] font-bold text-white">${name}</span>
          <span class="text-[12px] font-extrabold ${met ? "text-green-300" : "text-red-300"}">${this.currency(total)}</span>
        </div>
        <div class="text-[9px] ${met ? "text-green-300/80" : "text-red-300"}">${met ? "✓ min met" : this.currency(min - total) + " to " + this.currency(min) + " min"}</div>
      </div>`
    }).join("")

    const grand = Object.values(totals).reduce((a, b) => a + b, 0)
    this.ribbonTotalTarget.textContent = this.currency(grand)
    this.submitButtonTarget.disabled = !this.deliveryDateTarget.value
  }

  // ---- Fun: savings celebration when picking the best price ----

  celebrateIfBest(cell) {
    const card = cell.closest("[data-mobile-order-builder-target=card]")
    const spread = parseFloat(card.dataset.spread || "0")
    if (cell.dataset.best !== "true" || !(spread > 0)) return
    this.flySavings(cell, spread)
    this.confetti(cell)
  }

  flySavings(fromEl, amount) {
    const rect = fromEl.getBoundingClientRect()
    const el = document.createElement("div")
    el.textContent = `+${this.currency(amount)} saved`
    el.style.cssText = `position:fixed;left:${rect.left + rect.width / 2}px;top:${rect.top - 12}px;` +
      "transform:translateX(-50%);z-index:90;background:#16A34A;color:#fff;font-weight:800;" +
      "font-size:15px;padding:7px 16px;border-radius:999px;pointer-events:none;" +
      "box-shadow:0 6px 20px rgba(22,163,74,.5);opacity:0;will-change:transform,opacity;"
    document.body.appendChild(el)
    el.animate([
      { transform: "translateX(-50%) translateY(6px) scale(.5)", opacity: 0 },
      { transform: "translateX(-50%) translateY(-12px) scale(1.18)", opacity: 1, offset: 0.14 },
      { transform: "translateX(-50%) translateY(-18px) scale(1)", opacity: 1, offset: 0.28 },
      { transform: "translateX(-50%) translateY(-34px) scale(1)", opacity: 1, offset: 0.62 },
      { transform: "translateX(-50%) translateY(-96px) scale(.92)", opacity: 0 },
    ], { duration: 1900, easing: "cubic-bezier(.25,.8,.35,1)", fill: "forwards" })
    setTimeout(() => el.remove(), 1950)
  }

  confetti(fromEl, count = 14) {
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
      const dur = 1500 + Math.random() * 500
      p.animate([
        { transform: "translate(0,0) rotate(0deg) scale(1)", opacity: 1 },
        { transform: `translate(${vx * 0.55}px, ${launch}px) rotate(${rot * 0.4}deg) scale(1.05)`, opacity: 1, offset: 0.3, easing: "cubic-bezier(.2,.9,.5,1)" },
        { transform: `translate(${vx * 0.9}px, ${launch * 0.2}px) rotate(${rot * 0.7}deg) scale(1)`, opacity: 1, offset: 0.55, easing: "cubic-bezier(.5,0,.8,.4)" },
        { transform: `translate(${vx}px, ${fall}px) rotate(${rot}deg) scale(.85)`, opacity: 0 },
      ], { duration: dur, easing: "linear", fill: "forwards" })
      setTimeout(() => p.remove(), dur + 50)
    }
  }

  // ---- Submit: serialize state into the form the server already understands ----

  formTargetConnected(form) {
    form.addEventListener("submit", () => this.writeHiddenFields())
  }

  writeHiddenFields() {
    const container = this.hiddenFieldsTarget
    container.innerHTML = ""
    Object.entries(this.state).forEach(([matchId, s]) => {
      if (s.qty <= 0) return
      container.insertAdjacentHTML("beforeend",
        `<input type="hidden" name="quantities[${matchId}]" value="${s.qty}">` +
        `<input type="hidden" name="supplier_overrides[${matchId}]" value="${s.supplierId}">` +
        (s.uom === "PC" ? `<input type="hidden" name="uom_overrides[${matchId}]" value="PC">` : ""))
    })
  }

  currency(n) {
    return "$" + Number(n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })
  }
}
