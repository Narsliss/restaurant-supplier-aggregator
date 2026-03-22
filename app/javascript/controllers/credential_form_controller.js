import { Controller } from "@hotwired/stimulus"

// Handles dynamic form behavior for supplier credentials
// - Shows/hides password field based on supplier's authentication type
// - Shows appropriate notice for 2FA-only or welcome_url suppliers
// - Changes username label to "Welcome URL" for welcome_url suppliers
export default class extends Controller {
  static targets = [
    "supplierSelect", "fieldsContainer", "passwordField", "passwordInput",
    "twoFaNotice", "welcomeUrlNotice",
    "usernameLabel", "usernameInput"
  ]
  static values = { suppliers: Object }

  connect() {
    this.updateFormState()
  }

  supplierChanged() {
    this.updateFormState()
  }

  updateFormState() {
    const supplierId = this.supplierSelectTarget.value

    if (!supplierId) {
      this.hideFieldsContainer()
      return
    }

    this.showFieldsContainer()

    const supplier = this.suppliersValue[supplierId] || {}
    const authType = typeof supplier === "string" ? supplier : supplier.auth_type
    const code = typeof supplier === "string" ? null : supplier.code

    switch (authType) {
      case "two_fa":
        this.hidePasswordField()
        this.showTwoFaNotice()
        this.hideWelcomeUrlNotice()
        this.setUsernameMode(code === "usfoods" ? "userid" : "email")
        break
      case "welcome_url":
        this.hidePasswordField()
        this.hideTwoFaNotice()
        this.showWelcomeUrlNotice()
        this.setUsernameMode("url")
        break
      default: // "password"
        this.showPasswordField()
        this.hideTwoFaNotice()
        this.hideWelcomeUrlNotice()
        this.setUsernameMode("email")
        break
    }
  }

  setUsernameMode(mode) {
    if (this.hasUsernameLabelTarget) {
      const labels = { url: "Welcome URL", userid: "User ID", email: "Email Address" }
      this.usernameLabelTarget.textContent = labels[mode] || "Email Address"
    }
    if (this.hasUsernameInputTarget) {
      const placeholders = {
        url: "https://www.whatchefswant.com/welcome/...",
        userid: "Enter your User ID",
        email: "you@restaurant.com"
      }
      this.usernameInputTarget.placeholder = placeholders[mode] || "you@restaurant.com"
    }
  }

  showFieldsContainer() {
    if (this.hasFieldsContainerTarget) {
      this.fieldsContainerTarget.classList.remove("hidden")
    }
  }

  hideFieldsContainer() {
    if (this.hasFieldsContainerTarget) {
      this.fieldsContainerTarget.classList.add("hidden")
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

  showWelcomeUrlNotice() {
    if (this.hasWelcomeUrlNoticeTarget) {
      this.welcomeUrlNoticeTarget.classList.remove("hidden")
    }
  }

  hideWelcomeUrlNotice() {
    if (this.hasWelcomeUrlNoticeTarget) {
      this.welcomeUrlNoticeTarget.classList.add("hidden")
    }
  }
}
