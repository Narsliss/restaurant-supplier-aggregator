import { Controller } from "@hotwired/stimulus"

// Handles dynamic form behavior for supplier credentials
// - Shows/hides password field based on supplier's authentication type
// - Shows 2FA notice for 2FA-only suppliers
export default class extends Controller {
  static targets = ["supplierSelect", "passwordField", "passwordInput", "twoFaNotice"]
  static values = { suppliers: Object }

  connect() {
    // Initialize form state based on current selection
    this.updateFormState()
  }

  supplierChanged() {
    this.updateFormState()
  }

  updateFormState() {
    const supplierId = this.supplierSelectTarget.value

    if (!supplierId) {
      // No supplier selected - show password field, hide notice
      this.showPasswordField()
      this.hideTwoFaNotice()
      return
    }

    const passwordRequired = this.suppliersValue[supplierId]

    if (passwordRequired) {
      this.showPasswordField()
      this.hideTwoFaNotice()
    } else {
      this.hidePasswordField()
      this.showTwoFaNotice()
    }
  }

  showPasswordField() {
    if (this.hasPasswordFieldTarget) {
      this.passwordFieldTarget.classList.remove("hidden")
      if (this.hasPasswordInputTarget) {
        this.passwordInputTarget.disabled = false
      }
    }
  }

  hidePasswordField() {
    if (this.hasPasswordFieldTarget) {
      this.passwordFieldTarget.classList.add("hidden")
      if (this.hasPasswordInputTarget) {
        this.passwordInputTarget.disabled = true
        this.passwordInputTarget.value = ""
      }
    }
  }

  showTwoFaNotice() {
    if (this.hasTwoFaNoticeTarget) {
      this.twoFaNoticeTarget.classList.remove("hidden")
    }
  }

  hideTwoFaNotice() {
    if (this.hasTwoFaNoticeTarget) {
      this.twoFaNoticeTarget.classList.add("hidden")
    }
  }
}
