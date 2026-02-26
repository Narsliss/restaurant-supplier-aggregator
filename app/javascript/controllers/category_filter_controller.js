import { Controller } from "@hotwired/stimulus"

// Handles dynamic subcategory filtering based on selected category.
// Categories data is passed via a Stimulus value on the controller element
// instead of a separate <script> tag + getElementById.
export default class extends Controller {
  static targets = ["category", "subcategory", "subcategoryWrapper"]
  static values = { categories: Object }

  connect() {
    this.categories = this.categoriesValue || {}
    this.updateSubcategoryVisibility()
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
