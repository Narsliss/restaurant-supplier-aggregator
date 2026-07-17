// Bottom-sheet month calendar — ported 1:1 from the approved comp
// (mockups/mobile-first: openCalendar/renderCalMonth). Used by the mobile
// order builder ribbon and the mobile cart's delivery date rows.

let state = null

function isoOf(d) {
  return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0")
}

export function tomorrowIso() {
  const d = new Date()
  d.setDate(d.getDate() + 1)
  return isoOf(d)
}

export function dateLabel(iso) {
  if (!iso) return "Pick date"
  if (iso === tomorrowIso()) return "Tomorrow"
  const [y, m, day] = iso.split("-").map(Number)
  return new Date(y, m - 1, day).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" })
}

export function openCalendar(selectedIso, onPick) {
  const sel = selectedIso || tomorrowIso()
  const [y, m] = sel.split("-").map(Number)
  state = { year: y, month: m - 1, selected: sel, onPick }

  let sheet = document.getElementById("mobile-cal-sheet")
  if (!sheet) {
    sheet = document.createElement("div")
    sheet.id = "mobile-cal-sheet"
    sheet.innerHTML = `
      <div data-cal-backdrop style="position:fixed;inset:0;background:rgba(45,52,54,.55);z-index:60;opacity:0;transition:opacity .35s ease"></div>
      <div data-cal-panel style="position:fixed;left:0;right:0;bottom:0;z-index:61;transform:translateY(100%);transition:transform .45s cubic-bezier(.22,1,.36,1)">
        <div class="bg-white rounded-t-3xl shadow-2xl" style="padding:20px 20px calc(28px + env(safe-area-inset-bottom))">
          <div style="width:36px;height:4px;border-radius:2px;background:#E5E7EB;margin:0 auto 14px"></div>
          <div class="flex items-center justify-between mb-3">
            <h3 class="font-heading text-lg font-semibold text-gray-900 tracking-wide">Delivery Date</h3>
            <button type="button" data-cal-close class="w-8 h-8 rounded-full bg-brand-stone text-gray-500 font-bold">✕</button>
          </div>
          <div data-cal-body></div>
        </div>
      </div>`
    document.body.appendChild(sheet)
    sheet.querySelector("[data-cal-backdrop]").addEventListener("click", closeCalendar)
    sheet.querySelector("[data-cal-close]").addEventListener("click", closeCalendar)
  }
  renderMonth()
  requestAnimationFrame(() => {
    sheet.querySelector("[data-cal-backdrop]").style.opacity = "1"
    sheet.querySelector("[data-cal-panel]").style.transform = "translateY(0)"
  })
}

export function closeCalendar() {
  const sheet = document.getElementById("mobile-cal-sheet")
  if (!sheet) return
  sheet.querySelector("[data-cal-backdrop]").style.opacity = "0"
  sheet.querySelector("[data-cal-panel]").style.transform = "translateY(100%)"
  setTimeout(() => sheet.remove(), 460)
}

function nav(delta) {
  state.month += delta
  if (state.month < 0) { state.month = 11; state.year-- }
  if (state.month > 11) { state.month = 0; state.year++ }
  renderMonth()
}

function pick(iso) {
  state.selected = iso
  state.onPick(iso)
  renderMonth()
  setTimeout(closeCalendar, 180)
}

function renderMonth() {
  const { year, month, selected } = state
  const body = document.querySelector("#mobile-cal-sheet [data-cal-body]")
  const first = new Date(year, month, 1)
  const daysInMonth = new Date(year, month + 1, 0).getDate()
  const minIso = tomorrowIso()
  const todayIso = isoOf(new Date())
  const now = new Date()
  const atCurrentMonth = year === now.getFullYear() && month === now.getMonth()

  let cells = ""
  for (let i = 0; i < first.getDay(); i++) cells += "<div></div>"
  for (let day = 1; day <= daysInMonth; day++) {
    const iso = isoOf(new Date(year, month, day))
    if (iso < minIso) {
      cells += `<div class="h-10 flex items-center justify-center text-sm cal-muted">${day}</div>`
    } else {
      const isSel = iso === selected
      const isToday = iso === todayIso
      cells += `<button type="button" data-cal-day="${iso}"
        class="h-10 rounded-xl flex items-center justify-center text-sm font-bold active:scale-90 transition-transform
        ${isSel ? "bg-brand-green text-white shadow-md shadow-brand-green/40" : isToday ? "text-brand-green ring-1 ring-brand-green" : "text-gray-900 hover:bg-brand-stone"}">${day}</button>`
    }
  }

  body.innerHTML = `
    <div class="flex items-center justify-between mb-2">
      <button type="button" data-cal-prev ${atCurrentMonth ? "disabled" : ""} class="w-9 h-9 rounded-xl bg-brand-stone flex items-center justify-center font-bold ${atCurrentMonth ? "cal-muted" : "text-gray-900"}">‹</button>
      <span class="font-heading font-semibold text-gray-900 tracking-wide">${first.toLocaleDateString("en-US", { month: "long", year: "numeric" })}</span>
      <button type="button" data-cal-next class="w-9 h-9 rounded-xl bg-brand-stone flex items-center justify-center font-bold text-gray-900">›</button>
    </div>
    <div class="grid grid-cols-7 mb-1">
      ${["S", "M", "T", "W", "T", "F", "S"].map(d => `<div class="text-center text-[11px] font-bold text-gray-500 py-1">${d}</div>`).join("")}
    </div>
    <div class="grid grid-cols-7 gap-y-1">${cells}</div>`

  body.querySelector("[data-cal-prev]")?.addEventListener("click", () => nav(-1))
  body.querySelector("[data-cal-next]").addEventListener("click", () => nav(1))
  body.querySelectorAll("[data-cal-day]").forEach(btn =>
    btn.addEventListener("click", () => pick(btn.dataset.calDay)))
}

// Shared celebration effects (comp timings — slow, weighted)

export function flySavings(fromEl, amountText) {
  const rect = fromEl.getBoundingClientRect()
  const el = document.createElement("div")
  el.textContent = amountText
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

export function confettiBurst(fromEl, count = 20) {
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
