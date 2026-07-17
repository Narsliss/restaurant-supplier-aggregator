import { Controller } from "@hotwired/stimulus"
import { openCalendar, tomorrowIso, dateLabel, flySavings, confettiBurst } from "controllers/mobile_calendar"

// Mobile order builder — matches the approved Comp A exactly:
// tapping a price cell turns THAT cell into a stepper (or a CASE/PIECE chooser
// when the supplier offers a piece price); an "In this order" section lists the
// built order below the results; the ribbon shows per-supplier totals vs
// minimums with a bottom-sheet calendar; best-price adds fire the savings
// fly-up + confetti.
//
// One selected supplier + qty (+ CS/PC uom) per product match — the
// AggregatedListOrderService contract. On submit, state serializes into
// quantities[] / supplier_overrides[] / uom_overrides[] hidden fields; the
// server-side ordering path is unchanged.
export default class extends Controller {
  static targets = ["form", "hiddenFields", "search", "categoryChip", "emptyState", "noResults",
                    "card", "cell", "orderSection", "orderCount", "orderLines",
                    "ribbon", "ribbonPills", "ribbonTotal", "dateLabel", "deliveryDate", "submitButton"]
  static values = { minimums: Object }

  connect() {
    this.state = {}    // matchId -> { supplierId, qty, uom }
    this.chooser = null // {matchId, supplierId} showing CASE/PIECE picker
    this.category = "all"

    if (!this.deliveryDateTarget.value) this.deliveryDateTarget.value = tomorrowIso()

    // Prefill from server-rendered quantities (returning from review)
    this.cardTargets.forEach(card => {
      const qty = parseInt(card.dataset.initialQty || "0", 10)
      if (qty > 0 && card.dataset.cheapestSupplierId) {
        this.state[card.dataset.matchId] = { supplierId: card.dataset.cheapestSupplierId, qty, uom: "CS" }
      }
    })

    this.cellTargets.forEach(cell => this.renderCell(cell))
    this.filter()
    this.renderOrderSection()
    this.refreshRibbon()
  }

  // ---- Filtering: blank search + All => results hidden (comp behavior) ----

  filter() {
    const q = (this.searchTarget.value || "").trim().toLowerCase()
    const blank = q === "" && this.category === "all"
    let visible = 0

    this.cardTargets.forEach(card => {
      let show
      if (blank) {
        show = false
      } else {
        const matchesQuery = q === "" || card.dataset.name.includes(q)
        const matchesCat = this.category === "all" ||
          (this.category === "__frequent__" ? card.dataset.frequent === "true" : card.dataset.category === this.category)
        show = matchesQuery && matchesCat
      }
      card.classList.toggle("hidden", !show)
      if (show) visible++
    })

    const hasLines = Object.keys(this.state).length > 0
    this.emptyStateTarget.classList.toggle("hidden", !(blank && !hasLines))
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

  // ---- Cell interaction (comp: the cell itself morphs) ----

  tapCell(event) {
    const cell = event.currentTarget.closest("[data-supplier-id]")
    const { matchId, supplierId } = cell.dataset
    const existing = this.state[matchId]

    if (existing && existing.supplierId === supplierId) {
      existing.qty += 1
      this.afterChange(matchId)
      return
    }
    // Piece option → show CASE/PIECE chooser first (comp behavior)
    if (cell.dataset.piecePrice) {
      this.chooser = { matchId, supplierId }
      this.renderMatchCells(matchId)
      return
    }
    this.select(cell, "CS")
  }

  pickUom(event) {
    const cell = event.currentTarget.closest("[data-supplier-id]")
    this.chooser = null
    this.select(cell, event.params.uom)
  }

  select(cell, uom) {
    const { matchId, supplierId } = cell.dataset
    const existing = this.state[matchId]
    const qty = existing ? existing.qty : 1
    const isNew = !existing
    this.state[matchId] = { supplierId, qty, uom }
    if (isNew) this.celebrateIfBest(cell)
    this.afterChange(matchId)
  }

  increment(event) { this.bump(event, +1) }
  decrement(event) { this.bump(event, -1) }

  bump(event, delta) {
    const matchId = event.currentTarget.closest("[data-supplier-id]")?.dataset.matchId ||
                    event.currentTarget.dataset.matchId
    const s = this.state[matchId]
    if (!s) return
    s.qty = Math.max(0, s.qty + delta)
    if (s.qty === 0) delete this.state[matchId]
    this.afterChange(matchId)
  }

  afterChange(matchId) {
    this.renderMatchCells(matchId)
    this.renderOrderSection()
    this.refreshRibbon()
    this.filter()
  }

  // ---- Cell rendering: price | chooser | stepper ----

  cellsFor(matchId) {
    return this.cellTargets.filter(c => c.dataset.matchId === matchId)
  }

  renderMatchCells(matchId) {
    this.cellsFor(matchId).forEach(cell => this.renderCell(cell))
  }

  renderCell(cell) {
    const d = cell.dataset
    const s = this.state[d.matchId]
    const selected = s && s.supplierId === d.supplierId
    const choosing = this.chooser && this.chooser.matchId === d.matchId && this.chooser.supplierId === d.supplierId
    const inStock = d.inStock !== "false"

    if (choosing) {
      cell.innerHTML = `
        <div class="rounded-lg border-2 border-brand-navy overflow-hidden text-center bg-white">
          <button type="button" data-action="mobile-order-builder#pickUom" data-mobile-order-builder-uom-param="CS"
                  class="w-full py-1 border-b border-gray-100 leading-tight">
            <span class="text-[9px] font-bold text-gray-400 block">CASE</span>
            <span class="text-[12px] font-extrabold text-brand-navy">${d.priceDisplay}</span>
          </button>
          <button type="button" data-action="mobile-order-builder#pickUom" data-mobile-order-builder-uom-param="PC"
                  class="w-full py-1 leading-tight">
            <span class="text-[9px] font-bold text-gray-400 block">PIECE</span>
            <span class="text-[12px] font-extrabold text-brand-navy">${d.pieceDisplay}</span>
          </button>
        </div>`
      return
    }

    if (selected) {
      cell.innerHTML = `
        <div class="rounded-lg border-2 border-brand-green bg-green-50 text-center pop">
          <div class="flex items-stretch justify-between">
            <button type="button" data-action="mobile-order-builder#decrement" class="w-6 py-1.5 text-base font-bold text-brand-green">−</button>
            <span class="text-[15px] font-extrabold text-brand-navy self-center">${s.qty}</span>
            <button type="button" data-action="mobile-order-builder#increment" class="w-6 py-1.5 text-base font-bold text-brand-green">+</button>
          </div>
          <div class="text-[9px] font-bold -mt-1 pb-1 text-brand-green">${d.short}${s.uom === "PC" ? " · PC" : ""}</div>
        </div>`
      return
    }

    const best = d.best === "true"
    cell.innerHTML = `
      <button type="button" data-action="mobile-order-builder#tapCell" ${inStock ? "" : "disabled"}
              class="w-full rounded-lg border py-1 px-0.5 text-center transition-transform active:scale-95
                     ${inStock ? "" : "opacity-50"}
                     ${best ? "border-green-500 bg-green-50" : "border-gray-200 bg-white"}">
        <div class="text-[9px] font-bold leading-none truncate ${best ? "text-green-700" : "text-gray-500"}">${d.short}${best ? ' <span class="text-green-600">★</span>' : ""}</div>
        <div class="text-[12px] font-extrabold leading-tight mt-0.5 ${best ? "text-green-800" : "text-brand-navy"}">${d.priceDisplay}</div>
        <div class="text-[9px] font-semibold text-gray-500 leading-tight truncate">${d.perUnit || ""}</div>
        <div class="text-[9px] text-gray-400 leading-tight truncate">${d.pack || (inStock ? "" : "Out")}</div>
      </button>`
  }

  // ---- "In this order" section (comp: separate line items with steppers) ----

  renderOrderSection() {
    const entries = Object.entries(this.state)
    this.orderSectionTarget.classList.toggle("hidden", entries.length === 0)
    this.orderCountTarget.textContent = entries.reduce((a, [, s]) => a + s.qty, 0)

    this.orderLinesTarget.innerHTML = entries.map(([matchId, s]) => {
      const card = this.cardTargets.find(c => c.dataset.matchId === matchId)
      const cell = this.cellsFor(matchId).find(c => c.dataset.supplierId === s.supplierId)
      if (!card || !cell) return ""
      const price = this.effectivePrice(cell, s.uom)
      return `
        <div class="bg-white rounded-xl border border-gray-200 px-3 py-2.5 flex items-center gap-2.5">
          <img src="${card.dataset.thumb}" alt="" class="w-9 h-9 rounded-lg object-cover border border-gray-100 bg-brand-stone shrink-0">
          <div class="flex-1 min-w-0">
            <p class="text-[15px] font-bold text-brand-navy truncate">${card.dataset.displayName}</p>
            <p class="text-[11px] text-gray-500"><span class="font-bold">${cell.dataset.short}</span>${s.uom === "PC" ? " · PC" : ""} · ${this.currency(price)} ea</p>
          </div>
          <div class="flex items-center gap-0.5">
            <button type="button" data-action="mobile-order-builder#decrement" data-match-id="${matchId}" class="w-8 h-8 rounded-lg bg-brand-stone flex items-center justify-center font-bold text-gray-600">−</button>
            <span class="w-7 text-center text-sm font-extrabold">${s.qty}</span>
            <button type="button" data-action="mobile-order-builder#increment" data-match-id="${matchId}" class="w-8 h-8 rounded-lg bg-brand-stone flex items-center justify-center font-bold text-gray-600">+</button>
          </div>
          <span class="text-sm font-extrabold text-brand-navy w-[62px] text-right">${this.currency(price * s.qty)}</span>
        </div>`
    }).join("")
  }

  // ---- Ribbon ----

  effectivePrice(cell, uom) {
    if (uom === "PC" && cell.dataset.piecePrice) return parseFloat(cell.dataset.piecePrice)
    return parseFloat(cell.dataset.price)
  }

  refreshRibbon() {
    const totals = {}
    const names = {}
    Object.entries(this.state).forEach(([matchId, s]) => {
      const cell = this.cellsFor(matchId).find(c => c.dataset.supplierId === s.supplierId)
      if (!cell) return
      totals[s.supplierId] = (totals[s.supplierId] || 0) + this.effectivePrice(cell, s.uom) * s.qty
      names[s.supplierId] = cell.dataset.short
    })

    const supplierIds = Object.keys(totals)
    this.ribbonTarget.classList.toggle("hidden", supplierIds.length === 0)
    if (supplierIds.length === 0) return

    this.ribbonPillsTarget.innerHTML = supplierIds.map(id => {
      const total = totals[id]
      const min = this.minimumsValue[id]
      const met = min == null || total >= min
      return `<div class="shrink-0 rounded-lg px-2.5 py-1.5 border ${met ? "bg-green-500/15 border-green-400/60" : "bg-red-500/15 border-red-400/60"}">
        <div class="flex items-center gap-1.5">
          <span class="text-[11px] font-bold text-white">${names[id]}</span>
          <span class="text-[12px] font-extrabold ${met ? "text-green-300" : "text-red-300"}">${this.currency(total)}</span>
        </div>
        <div class="text-[9px] ${met ? "text-green-300/80" : "text-red-300"}">${met ? "✓ min met" : this.currency(min - total) + " to " + this.currency(min) + " min"}</div>
      </div>`
    }).join("")

    this.ribbonTotalTarget.textContent = this.currency(Object.values(totals).reduce((a, b) => a + b, 0))
    this.dateLabelTarget.textContent = dateLabel(this.deliveryDateTarget.value)
    this.submitButtonTarget.disabled = !this.deliveryDateTarget.value
  }

  // ---- Calendar bottom sheet (comp component) ----

  openDatePicker() {
    openCalendar(this.deliveryDateTarget.value, iso => {
      this.deliveryDateTarget.value = iso
      this.refreshRibbon()
    })
  }

  // ---- Savings celebration: always fires when adding the ★ best-price cell ----

  celebrateIfBest(cell) {
    if (cell.dataset.best !== "true") return
    const prices = this.cellsFor(cell.dataset.matchId)
      .filter(c => c.dataset.inStock !== "false")
      .map(c => parseFloat(c.dataset.price))
      .filter(p => p > 0)
    if (prices.length < 2) return
    const saved = Math.max(...prices) - parseFloat(cell.dataset.price)
    if (saved <= 0) return
    flySavings(cell, `+${this.currency(saved)} saved`)
    confettiBurst(cell, 14)
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
