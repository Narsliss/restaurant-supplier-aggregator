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
  static targets = ["form", "hiddenFields", "search", "searchClear", "categoryChip", "emptyState", "noResults",
                    "card", "cell", "orderSection", "orderCount", "orderLines",
                    "listSectionHeader", "otherSectionHeader",
                    "catalogHeader", "catalogResults", "catalogCount",
                    "ribbon", "ribbonPills", "ribbonTotal", "dateLabel", "deliveryDate", "submitButton"]
  static values = { minimums: Object, listId: Number }

  connect() {
    this.state = {}    // matchId -> { supplierId, qty, uom }
    this.chooser = null // {matchId, supplierId} showing CASE/PIECE picker
    this.category = "all"

    if (!this.deliveryDateTarget.value) this.deliveryDateTarget.value = tomorrowIso()

    // The server-rendered prefill IS the chef's singular working order
    // (CurrentOrder) — it saved on every change last time and repopulates
    // here. There is deliberately no client-side draft store.
    this.cardTargets.forEach(card => {
      const qty = parseInt(card.dataset.initialQty || "0", 10)
      if (qty <= 0) return
      const supplierId = card.dataset.initialSupplierId || card.dataset.cheapestSupplierId
      if (!supplierId) return
      this.state[card.dataset.matchId] = { supplierId, qty, uom: card.dataset.initialUom || "CS" }
    })

    this.cellTargets.forEach(cell => this.renderCell(cell))
    this.filter()
    this.renderOrderSection()
    this.refreshRibbon()
  }

  disconnect() {
    this.closeSuggestions()
    // Flush any pending save before the page goes away
    if (this._syncTimer) {
      clearTimeout(this._syncTimer)
      this.pushOrder()
    }
  }

  // ---- Working-order persistence: every change saves to the server ----

  syncOrder() {
    clearTimeout(this._syncTimer)
    this._syncTimer = setTimeout(() => {
      this._syncTimer = null
      this.pushOrder()
    }, 400)
  }

  pushOrder() {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch("/current_order", {
      method: "PUT",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": token },
      keepalive: true,
      body: JSON.stringify({
        aggregated_list_id: this.listIdValue,
        state: this.state,
        delivery_date: this.deliveryDateTarget.value
      })
    }).catch(() => {})
  }

  // "Clear order" — the one manual way to empty the working order.
  // Two-tap confirm (no native dialog: Android Chrome's "suppress dialogs"
  // checkbox would silently kill window.confirm for the whole session).
  clearOrder(event) {
    const btn = event.currentTarget
    if (!this._clearArmed) {
      this._clearArmed = true
      this._clearOriginal = btn.innerHTML
      btn.textContent = "Tap again"
      btn.classList.remove("bg-red-50", "text-red-500")
      btn.classList.add("bg-red-600", "text-white")
      this._clearArmTimer = setTimeout(() => this.disarmClear(btn), 3500)
      return
    }
    this.disarmClear(btn)

    clearTimeout(this._syncTimer)
    this._syncTimer = null
    this.state = {}
    this.chooser = null
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(`/current_order?aggregated_list_id=${this.listIdValue}`, {
      method: "DELETE",
      headers: { "X-CSRF-Token": token }
    }).catch(() => {})
    this.cellTargets.forEach(cell => this.renderCell(cell))
    this.renderOrderSection()
    this.refreshRibbon()
    this.filter()
  }

  disarmClear(btn) {
    clearTimeout(this._clearArmTimer)
    this._clearArmed = false
    if (this._clearOriginal != null) {
      btn.innerHTML = this._clearOriginal
      btn.classList.add("bg-red-50", "text-red-500")
      btn.classList.remove("bg-red-600", "text-white")
    }
  }

  // ---- Filtering: blank search + All => results hidden (comp behavior) ----

  clearSearch() {
    this.searchTarget.value = ""
    this.filter()
    this.searchTarget.focus()
  }

  filter() {
    const q = (this.searchTarget.value || "").trim().toLowerCase()
    if (this.hasSearchClearTarget) this.searchClearTarget.classList.toggle("hidden", this.searchTarget.value === "")
    const blank = q === "" && this.category === "all"
    let visible = 0
    let visibleOnList = 0
    let visibleOther = 0

    this.cardTargets.forEach(card => {
      let show
      if (blank) {
        show = false
      } else {
        // Match the canonical name OR any supplier's own product name — chefs
        // type the words their supplier uses.
        const matchesQuery = q === "" ||
          card.dataset.name.includes(q) ||
          (card.dataset.supplierNames || "").includes(q)
        const matchesCat = this.category === "all" ||
          (this.category === "__frequent__" ? card.dataset.frequent === "true" : card.dataset.category === this.category)
        show = matchesQuery && matchesCat
      }
      card.classList.toggle("hidden", !show)
      if (show) {
        visible++
        if (card.dataset.onList === "true") visibleOnList++
        else visibleOther++
      }
    })

    // Group headers show whenever that group has results and there's more than
    // one group on screen (the catalog group counts, so a matched-list hit plus
    // catalog hits still gets labelled).
    this._visibleOnList = visibleOnList
    this._visibleOther = visibleOther
    this.updateSectionHeaders()

    // "Everything else" — the full catalog, fetched server-side
    if (blank) {
      this.clearCatalog()
    } else {
      this.searchCatalog(q)
    }

    const hasLines = Object.keys(this.state).length > 0
    this.emptyStateTarget.classList.toggle("hidden", !(blank && !hasLines))
    this.noResultsTarget.classList.toggle("hidden", blank || visible > 0)
  }

  // ---- Section headers ----

  updateSectionHeaders() {
    const onList = this._visibleOnList || 0
    const matched = this._visibleOther || 0
    const catalog = this._catalogCount || 0
    const groups = [onList, matched, catalog].filter(n => n > 0).length
    const label = groups > 1

    this.toggleHeader(this.hasListSectionHeaderTarget && this.listSectionHeaderTarget, label && onList > 0)
    this.toggleHeader(this.hasOtherSectionHeaderTarget && this.otherSectionHeaderTarget, label && matched > 0)
    this.toggleHeader(this.hasCatalogHeaderTarget && this.catalogHeaderTarget, label && catalog > 0)
  }

  toggleHeader(el, show) {
    if (!el) return
    el.classList.toggle("hidden", !show)
    el.classList.toggle("flex", !!show)
  }

  // ---- "Everything else": full-catalog search across connected suppliers ----

  clearCatalog() {
    clearTimeout(this._catalogTimer)
    this._catalogQuery = null
    this._catalogCount = 0
    if (this.hasCatalogResultsTarget) {
      this.catalogResultsTarget.innerHTML = ""
      this.catalogResultsTarget.classList.add("hidden")
    }
    if (this.hasCatalogCountTarget) this.catalogCountTarget.textContent = ""
    this.updateSectionHeaders()
  }

  searchCatalog(q) {
    if (!this.hasCatalogResultsTarget) return
    if (q.length < 2) return this.clearCatalog()
    if (q === this._catalogQuery) return

    clearTimeout(this._catalogTimer)
    this._catalogTimer = setTimeout(() => {
      this._catalogQuery = q
      this.catalogResultsTarget.classList.remove("hidden")
      this.catalogResultsTarget.innerHTML = `
        <div class="flex items-center justify-center gap-2 py-4 text-gray-400">
          <svg class="h-4 w-4 animate-spin" fill="none" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path></svg>
          <span class="text-[12px] font-medium">Searching all suppliers…</span>
        </div>`
      this._catalogCount = 1 // show the header while loading
      this.updateSectionHeaders()

      fetch(`/aggregated_lists/${this.listIdValue}/builder_catalog_search?q=${encodeURIComponent(q)}`,
            { headers: { Accept: "application/json" } })
        .then(r => r.ok ? r.json() : Promise.reject(r.status))
        .then(data => {
          if (this._catalogQuery !== q) return // a newer query superseded this one
          this.renderCatalog(data)
        })
        .catch(() => {
          if (this._catalogQuery !== q) return
          this.catalogResultsTarget.innerHTML =
            `<p class="text-[12px] text-gray-400 text-center py-3">Couldn't reach the supplier catalogs. Check your connection.</p>`
        })
    }, 300)
  }

  renderCatalog(data) {
    const results = data.results || []
    this._catalogCount = results.length
    this.catalogResultsTarget.classList.toggle("hidden", results.length === 0)

    if (this.hasCatalogCountTarget) {
      this.catalogCountTarget.textContent = data.capped
        ? `${results.length} of ${data.total} — type more to narrow`
        : (results.length > 0 ? `${results.length}` : "")
    }

    this.catalogResultsTarget.innerHTML = results.map(r => `
      <div class="bg-white rounded-2xl border border-gray-200 px-2.5 py-2 mb-2 flex items-center gap-2.5"
           data-catalog-row data-supplier-product-id="${r.supplier_product_id}">
        <div class="flex-1 min-w-0">
          <p class="text-[14px] font-bold text-brand-navy leading-snug">${this.escape(r.name)}</p>
          <p class="text-[11px] text-gray-500 mt-0.5">
            <span class="font-bold">${this.escape(r.supplier)}</span>
            · ${r.price_display}${r.pack_size ? " · " + this.escape(r.pack_size) : ""}${r.in_stock ? "" : ' · <span class="text-red-500 font-bold">Out of stock</span>'}
          </p>
          ${r.per_unit ? `<p class="text-[10px] text-gray-400">${this.escape(r.per_unit)}</p>` : ""}
        </div>
        <button type="button" data-catalog-add
                class="shrink-0 w-10 h-10 rounded-xl bg-brand-green text-white font-bold text-xl flex items-center justify-center active:bg-brand-green-dark">+</button>
      </div>`).join("")

    this.catalogResultsTarget.querySelectorAll("[data-catalog-add]").forEach(btn => {
      btn.addEventListener("click", event => this.addCatalogItem(event))
    })

    this.updateSectionHeaders()
  }

  // Tap + on a catalog row: make it orderable, then add it to the working order.
  addCatalogItem(event) {
    const btn = event.currentTarget
    const row = btn.closest("[data-catalog-row]")
    if (!row || btn.disabled) return

    btn.disabled = true
    btn.innerHTML = `<svg class="h-4 w-4 animate-spin" fill="none" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path></svg>`

    const token = document.querySelector('meta[name="csrf-token"]')?.content
    fetch(`/aggregated_lists/${this.listIdValue}/builder_add_catalog_item`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": token, Accept: "application/json" },
      body: JSON.stringify({ supplier_product_id: row.dataset.supplierProductId })
    })
      .then(r => r.json().then(body => r.ok ? body : Promise.reject(body)))
      .then(card => {
        this.injectCard(card)
        this.state[card.match_id] = { supplierId: String(card.supplier_id), qty: 1, uom: "CS" }
        btn.textContent = "✓"
        btn.classList.remove("bg-brand-green")
        btn.classList.add("bg-gray-300")
        row.classList.add("opacity-60")
        this.renderOrderSection()
        this.refreshRibbon()
        this.syncOrder()
      })
      .catch(err => {
        btn.disabled = false
        btn.textContent = "+"
        const msg = (err && err.error) || "Couldn't add that item. Please try again."
        const note = document.createElement("p")
        note.className = "text-[11px] text-red-500 mt-1"
        note.textContent = msg
        row.appendChild(note)
      })
  }

  // Build a real builder card for the newly-orderable product so the order
  // section, ribbon, submit fields and autosave all work unchanged.
  injectCard(card) {
    const main = this.catalogResultsTarget.parentElement
    const el = document.createElement("div")
    el.className = "bg-white rounded-2xl border border-gray-200 p-2.5"
    el.style.order = "1"
    el.setAttribute("data-mobile-order-builder-target", "card")
    el.dataset.matchId = String(card.match_id)
    el.dataset.name = (card.display_name || "").toLowerCase()
    el.dataset.supplierNames = (card.display_name || "").toLowerCase()
    el.dataset.displayName = card.display_name || ""
    el.dataset.thumb = card.thumb || ""
    el.dataset.category = card.category || "Other"
    el.dataset.frequent = "false"
    el.dataset.nonPerishable = "false"
    el.dataset.onList = "false"
    el.dataset.cheapestSupplierId = String(card.supplier_id)
    el.dataset.initialQty = "0"

    el.innerHTML = `
      <div class="flex gap-3 mb-2.5 items-center">
        <img src="${card.thumb}" alt="" loading="lazy" decoding="async"
             class="w-20 h-20 rounded-xl object-cover border border-gray-100 bg-brand-stone shrink-0">
        <div class="min-w-0 flex-1">
          <p class="font-bold text-brand-navy text-lg leading-snug">${this.escape(card.display_name)}</p>
          <p class="text-sm text-gray-500 mt-0.5">${this.escape(card.category)}</p>
        </div>
      </div>
      <div class="grid gap-1.5" style="grid-template-columns: repeat(1, minmax(0, 1fr));"></div>`

    const cell = document.createElement("div")
    cell.setAttribute("data-mobile-order-builder-target", "cell")
    cell.dataset.matchId = String(card.match_id)
    cell.dataset.supplierId = String(card.supplier_id)
    cell.dataset.short = card.short || ""
    cell.dataset.price = String(card.price)
    cell.dataset.priceDisplay = card.price_display || ""
    cell.dataset.perUnit = card.per_unit || ""
    cell.dataset.pack = card.pack || ""
    cell.dataset.best = "false"
    cell.dataset.orderedCount = "0"
    cell.dataset.inStock = String(card.in_stock)
    if (card.piece_price) {
      cell.dataset.piecePrice = String(card.piece_price)
      cell.dataset.pieceDisplay = card.piece_display || ""
    }
    el.querySelector(".grid").appendChild(cell)

    main.insertBefore(el, this.catalogResultsTarget)
    this.renderCell(cell)
    this._cellIndex = null // new cell — rebuild the lookup index
  }

  escape(text) {
    const div = document.createElement("div")
    div.textContent = text == null ? "" : String(text)
    return div.innerHTML
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
    this.syncOrder()
  }

  // ---- Cell rendering: price | chooser | stepper ----

  cellsFor(matchId) {
    // Indexed once — filtering all cells per lookup is O(cards × cells) and
    // visibly freezes phones on 1000+ product lists (suggestion sheet build)
    if (!this._cellIndex) {
      this._cellIndex = {}
      this.cellTargets.forEach(c => {
        (this._cellIndex[c.dataset.matchId] ||= []).push(c)
      })
    }
    return this._cellIndex[matchId] || []
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
      if (met) {
        return `<div class="shrink-0 rounded-lg px-2.5 py-1.5 border bg-green-500/15 border-green-400/60">
          <div class="flex items-center gap-1.5">
            <span class="text-[11px] font-bold text-white">${names[id]}</span>
            <span class="text-[12px] font-extrabold text-green-300">${this.currency(total)}</span>
          </div>
          <div class="text-[9px] text-green-300/80">✓ min met</div>
        </div>`
      }
      // Unmet minimum: the pill is tappable and opens the suggestion sheet
      return `<button type="button" data-action="mobile-order-builder#openSuggestions" data-supplier-id="${id}"
                      class="shrink-0 rounded-lg px-2.5 py-1.5 border bg-red-500/15 border-red-400/60 text-left active:bg-red-500/25">
        <div class="flex items-center gap-1.5">
          <span class="text-[11px] font-bold text-white">${names[id]}</span>
          <span class="text-[12px] font-extrabold text-red-300">${this.currency(total)}</span>
        </div>
        <div class="text-[9px] text-red-300">${this.currency(min - total)} to ${this.currency(min)} min · <span class="underline font-bold">add items</span></div>
      </button>`
    }).join("")

    this.ribbonTotalTarget.textContent = this.currency(Object.values(totals).reduce((a, b) => a + b, 0))
    this.dateLabelTarget.textContent = dateLabel(this.deliveryDateTarget.value)
    this.submitButtonTarget.disabled = !this.deliveryDateTarget.value
  }

  // ---- Minimum-suggestion sheet: tap an unmet supplier pill to fill the gap ----
  // Priority per Carmin's spec: items you usually order from that supplier,
  // then non-perishables it carries, then items where it has the best price.

  openSuggestions(event) {
    const supplierId = event.currentTarget.dataset.supplierId
    this.closeSuggestions()
    const short = this.supplierShortName(supplierId)

    // The sheet opens IMMEDIATELY with a spinner; the suggestion list builds
    // after a yield so the animation + spinner paint first — on big lists the
    // build takes long enough that a silent tap feels broken (chef feedback).
    const sheet = document.createElement("div")
    sheet.className = "fixed inset-0 z-[60]"
    sheet.innerHTML = `
      <div class="absolute inset-0 bg-black/40 opacity-0 transition-opacity duration-200" data-suggestion-backdrop></div>
      <div class="absolute inset-x-0 bottom-0 bg-white rounded-t-2xl max-h-[75vh] flex flex-col translate-y-full transition-transform duration-200 ease-out" data-suggestion-panel>
        <div class="px-4 pt-3 pb-2 border-b border-gray-100 flex items-center justify-between">
          <div>
            <p class="font-heading font-bold text-brand-navy text-base">Fill ${short} minimum</p>
            <p class="text-[12px] text-gray-500" data-suggestion-gap></p>
          </div>
          <button type="button" data-suggestion-done class="text-sm font-bold text-brand-green px-3 py-1.5">Done</button>
        </div>
        <div class="overflow-y-auto px-3 pb-6 pt-1" data-suggestion-body>
          <div class="flex items-center justify-center gap-2 py-10 text-gray-400">
            <svg class="h-5 w-5 animate-spin" fill="none" viewBox="0 0 24 24"><circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle><path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path></svg>
            <span class="text-sm font-medium">Finding items…</span>
          </div>
        </div>
      </div>`

    sheet.querySelector("[data-suggestion-backdrop]").addEventListener("click", () => this.closeSuggestions())
    sheet.querySelector("[data-suggestion-done]").addEventListener("click", () => this.closeSuggestions())
    document.body.appendChild(sheet)
    this._suggestionSheet = sheet
    this._suggestionSupplierId = supplierId
    this.updateSuggestionGap(supplierId)

    // Slide up + fade in just after insertion. setTimeout (not rAF): fires
    // even in throttled tabs.
    setTimeout(() => {
      sheet.querySelector("[data-suggestion-panel]")?.classList.remove("translate-y-full")
      sheet.querySelector("[data-suggestion-backdrop]")?.classList.remove("opacity-0")
    }, 20)

    // Populate after the sheet is visibly opening
    setTimeout(() => this.populateSuggestions(sheet, supplierId), 60)
  }

  populateSuggestions(sheet, supplierId) {
    if (this._suggestionSheet !== sheet) return // closed before build finished
    const sections = this.buildSuggestions(supplierId)
    const body = sheet.querySelector("[data-suggestion-body]")
    body.innerHTML = sections.length ? "" : '<p class="text-sm text-gray-400 text-center py-8">No more items from this supplier to suggest.</p>'

    sections.forEach(section => {
      const header = document.createElement("p")
      header.className = "text-[11px] font-bold text-gray-400 uppercase tracking-widest mt-3 mb-1.5 px-1"
      header.textContent = section.title
      body.appendChild(header)
      section.items.forEach(({ card, cell }) => {
        const row = document.createElement("div")
        row.className = "flex items-center gap-2.5 bg-white border border-gray-200 rounded-xl px-2.5 py-2 mb-1.5"
        row.innerHTML = `
          <img src="${card.dataset.thumb}" alt="" class="w-9 h-9 rounded-lg object-cover border border-gray-100 bg-brand-stone shrink-0">
          <div class="flex-1 min-w-0">
            <p class="text-[13px] font-bold text-brand-navy truncate">${card.dataset.displayName}</p>
            <p class="text-[11px] text-gray-500">${cell.dataset.priceDisplay}${cell.dataset.pack ? " · " + cell.dataset.pack : ""}</p>
          </div>
          <button type="button" class="shrink-0 w-9 h-9 rounded-lg bg-brand-green text-white font-bold text-lg flex items-center justify-center active:bg-brand-green-dark">+</button>`
        row.querySelector("button").addEventListener("click", btnEvent => {
          this.select(cell, "CS")
          const btn = btnEvent.currentTarget
          btn.textContent = "✓"
          btn.disabled = true
          btn.classList.remove("bg-brand-green")
          btn.classList.add("bg-gray-300")
          this.updateSuggestionGap(supplierId)
        })
        body.appendChild(row)
      })
    })
  }

  closeSuggestions() {
    if (this._suggestionSheet) {
      this._suggestionSheet.remove()
      this._suggestionSheet = null
    }
  }

  buildSuggestions(supplierId) {
    const usual = [], pantry = [], best = []
    this.cardTargets.forEach(card => {
      const matchId = card.dataset.matchId
      if (this.state[matchId]) return
      const cell = this.cellsFor(matchId).find(c => c.dataset.supplierId === supplierId)
      if (!cell || cell.dataset.inStock === "false" || !(parseFloat(cell.dataset.price) > 0)) return
      const count = parseInt(cell.dataset.orderedCount || "0", 10)
      if (count >= 2) usual.push({ card, cell, count })
      else if (card.dataset.nonPerishable === "true") pantry.push({ card, cell, count })
      else if (cell.dataset.best === "true") best.push({ card, cell, count })
    })
    usual.sort((a, b) => b.count - a.count)
    return [
      { title: "You usually order", items: usual.slice(0, 6) },
      { title: "Pantry staples", items: pantry.slice(0, 6) },
      { title: "Best price here", items: best.slice(0, 6) }
    ].filter(s => s.items.length > 0)
  }

  supplierShortName(supplierId) {
    const cell = this.cellTargets.find(c => c.dataset.supplierId === supplierId)
    return cell ? cell.dataset.short : "supplier"
  }

  updateSuggestionGap(supplierId) {
    if (!this._suggestionSheet) return
    const gapEl = this._suggestionSheet.querySelector("[data-suggestion-gap]")
    const min = this.minimumsValue[supplierId]
    let total = 0
    Object.entries(this.state).forEach(([matchId, s]) => {
      if (s.supplierId !== supplierId) return
      const cell = this.cellsFor(matchId).find(c => c.dataset.supplierId === supplierId)
      if (cell) total += this.effectivePrice(cell, s.uom) * s.qty
    })
    if (min == null || total >= min) {
      gapEl.textContent = "✓ Minimum met"
      gapEl.classList.remove("text-gray-500")
      gapEl.classList.add("text-brand-green", "font-bold")
    } else {
      gapEl.textContent = `${this.currency(min - total)} more to reach the ${this.currency(min)} minimum`
    }
  }

  // ---- Calendar bottom sheet (comp component) ----

  openDatePicker() {
    openCalendar(this.deliveryDateTarget.value, iso => {
      this.deliveryDateTarget.value = iso
      this.refreshRibbon()
      this.syncOrder()
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
    form.addEventListener("submit", () => {
      this.writeHiddenFields()
      // Create Cart does NOT clear the working order — chefs go back for
      // forgotten items. Only placing the order (server-side) clears it.
      // Flush the latest state so the server copy matches what was reviewed.
      clearTimeout(this._syncTimer)
      this._syncTimer = null
      this.pushOrder()
    })
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
