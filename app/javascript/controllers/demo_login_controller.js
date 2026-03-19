import { Controller } from "@hotwired/stimulus"

// Fills the login form with demo credentials and auto-submits
export default class extends Controller {
  fill(event) {
    const email = event.params.email
    const password = event.params.password

    const emailField = document.querySelector("#user_email")
    const passwordField = document.querySelector("#user_password")
    const form = emailField?.closest("form")

    if (emailField && passwordField && form) {
      emailField.value = email
      passwordField.value = password
      form.requestSubmit()
    }
  }
}
