import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["weeklyChart", "monthlyChart", "weeklyBtn", "monthlyBtn"]

  connect() {
    this.showWeekly()
  }

  showWeekly() {
    this.weeklyChartTarget.classList.remove("hidden")
    this.monthlyChartTarget.classList.add("hidden")
    this.weeklyBtnTarget.classList.add("bg-brand-orange", "text-white")
    this.weeklyBtnTarget.classList.remove("text-gray-500", "hover:text-gray-700")
    this.monthlyBtnTarget.classList.remove("bg-brand-orange", "text-white")
    this.monthlyBtnTarget.classList.add("text-gray-500", "hover:text-gray-700")
  }

  showMonthly() {
    this.monthlyChartTarget.classList.remove("hidden")
    this.weeklyChartTarget.classList.add("hidden")
    this.monthlyBtnTarget.classList.add("bg-brand-orange", "text-white")
    this.monthlyBtnTarget.classList.remove("text-gray-500", "hover:text-gray-700")
    this.weeklyBtnTarget.classList.remove("bg-brand-orange", "text-white")
    this.weeklyBtnTarget.classList.add("text-gray-500", "hover:text-gray-700")
  }
}
