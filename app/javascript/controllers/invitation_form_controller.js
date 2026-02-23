import { Controller } from "@hotwired/stimulus"

// Handles showing/hiding location fields based on selected role in the invitation form
export default class extends Controller {
  static targets = ["roleSelect", "chefLocation", "managerLocations"]

  connect() {
    this.roleChanged()
  }

  roleChanged() {
    const role = this.roleSelectTarget.value

    if (role === "chef") {
      this.chefLocationTarget.classList.remove("hidden")
      this.managerLocationsTarget.classList.add("hidden")
    } else if (role === "manager") {
      this.chefLocationTarget.classList.add("hidden")
      this.managerLocationsTarget.classList.remove("hidden")
    } else {
      this.chefLocationTarget.classList.add("hidden")
      this.managerLocationsTarget.classList.add("hidden")
    }
  }
}
