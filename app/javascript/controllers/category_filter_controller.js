import { Controller } from "@hotwired/stimulus"

// Handles dynamic subcategory filtering based on selected category
export default class extends Controller {
  static targets = ["category", "subcategory", "subcategoryWrapper"]

  connect() {
    this.loadCategories()
    this.updateSubcategoryVisibility()
  }

  loadCategories() {
    const dataElement = document.getElementById("categories-data")
    if (dataElement) {
      try {
        this.categories = JSON.parse(dataElement.textContent)
      } catch (e) {
        console.error("Failed to parse categories data:", e)
        this.categories = {}
      }
    } else {
      this.categories = {}
    }
  }

  categoryChanged() {
    const selectedCategory = this.categoryTarget.value
    this.updateSubcategories(selectedCategory)
    this.updateSubcategoryVisibility()
  }

  updateSubcategories(category) {
    if (!this.hasSubcategoryTarget) return

    const subcategorySelect = this.subcategoryTarget

    // Clear existing options except prompt
    subcategorySelect.innerHTML = '<option value="">All Subcategories</option>'

    if (category && this.categories[category]) {
      const subcategories = this.categories[category].subcategories || []
      subcategories.forEach(sub => {
        const option = document.createElement("option")
        option.value = sub
        option.textContent = sub
        subcategorySelect.appendChild(option)
      })
    }
  }

  updateSubcategoryVisibility() {
    if (!this.hasSubcategoryWrapperTarget) return

    const hasCategory = this.categoryTarget.value !== ""
    if (hasCategory) {
      this.subcategoryWrapperTarget.classList.remove("hidden")
    } else {
      this.subcategoryWrapperTarget.classList.add("hidden")
    }
  }
}
