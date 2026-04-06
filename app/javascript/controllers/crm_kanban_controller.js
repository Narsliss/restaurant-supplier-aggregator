import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["column", "card", "panel", "panelTitle", "panelContent", "panelLink"]
  static values = { moveUrl: String }

  connect() {
    this.draggedCard = null
    this.isDragging = false
  }

  // ── Card Events ──

  cardDragStart(event) {
    this.isDragging = true
    this.draggedCard = event.currentTarget
    this.draggedLeadId = event.currentTarget.dataset.leadId
    event.currentTarget.classList.add("opacity-50")
    event.dataTransfer.effectAllowed = "move"
    // Set data for native drag (also used as fallback)
    event.dataTransfer.setData("text/plain", this.draggedLeadId)
  }

  cardDragEnd(event) {
    event.currentTarget.classList.remove("opacity-50")
    this.draggedCard = null
    this.draggedLeadId = null
    setTimeout(() => { this.isDragging = false }, 100)
    // Clean up all column highlights
    this.columnTargets.forEach(col => {
      col.classList.remove("ring-2", "ring-brand-green", "ring-inset")
      col._dragCounter = 0
    })
  }

  // ── Column Events ──
  // Use a counter per column to handle child element enter/leave bubbling

  columnDragEnter(event) {
    event.preventDefault()
    const col = event.currentTarget
    col._dragCounter = (col._dragCounter || 0) + 1
    col.classList.add("ring-2", "ring-brand-green", "ring-inset")
  }

  columnDragOver(event) {
    // Must preventDefault to allow drop
    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
  }

  columnDragLeave(event) {
    const col = event.currentTarget
    col._dragCounter = (col._dragCounter || 1) - 1
    if (col._dragCounter <= 0) {
      col._dragCounter = 0
      col.classList.remove("ring-2", "ring-brand-green", "ring-inset")
    }
  }

  async columnDrop(event) {
    event.preventDefault()
    event.stopPropagation()

    const col = event.currentTarget
    col.classList.remove("ring-2", "ring-brand-green", "ring-inset")
    col._dragCounter = 0

    // Use stored leadId — DataTransfer.getData() can be empty in real browser drags
    const leadId = this.draggedLeadId || event.dataTransfer.getData("text/plain")
    const newStage = col.dataset.stage

    if (!leadId || !newStage) return

    // Move card in DOM immediately
    const cardsContainer = col.querySelector("[data-cards]")
    if (this.draggedCard && cardsContainer) {
      cardsContainer.appendChild(this.draggedCard)
      this.draggedCard.classList.remove("opacity-50")
    }

    // Update column counts
    this.columnTargets.forEach(c => {
      const count = c.querySelectorAll("[data-crm-kanban-target='card']").length
      const el = c.querySelector("[data-count]")
      if (el) el.textContent = count
    })

    // Persist to server
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    try {
      const response = await fetch(`${this.moveUrlValue || "/crm/leads"}/${leadId}/move_stage`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
          "Accept": "application/json"
        },
        body: JSON.stringify({ pipeline_stage: newStage })
      })

      if (!response.ok) {
        window.location.reload()
      }
    } catch {
      window.location.reload()
    }
  }

  // ── Slide-over Panel ──

  openDetail(event) {
    // Don't open if we just dragged
    if (this.isDragging) return

    event.preventDefault()
    event.stopPropagation()

    const card = event.currentTarget
    const leadId = card.dataset.leadId
    const showUrl = card.dataset.leadShowUrl

    if (!this.hasPanelTarget) return

    this.panelTarget.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
    this.panelTitleTarget.textContent = card.querySelector(".font-medium")?.textContent || "Lead"
    this.panelLinkTarget.href = showUrl
    this.panelContentTarget.innerHTML = `
      <div class="animate-pulse space-y-4">
        <div class="h-4 bg-gray-200 rounded w-3/4"></div>
        <div class="h-4 bg-gray-200 rounded w-1/2"></div>
      </div>
    `

    fetch(`/crm/leads/${leadId}/detail_panel`, {
      headers: { "Accept": "text/html" }
    })
      .then(r => r.ok ? r.text() : Promise.reject())
      .then(html => { this.panelContentTarget.innerHTML = html })
      .catch(() => {
        this.panelContentTarget.innerHTML = `
          <p class="text-gray-500 text-sm">Could not load details.</p>
          <a href="${showUrl}" class="mt-4 inline-block text-brand-green hover:underline text-sm font-medium">Open full page &rarr;</a>
        `
      })
  }

  closeDetail() {
    if (this.hasPanelTarget) {
      this.panelTarget.classList.add("hidden")
      document.body.classList.remove("overflow-hidden")
    }
  }
}
