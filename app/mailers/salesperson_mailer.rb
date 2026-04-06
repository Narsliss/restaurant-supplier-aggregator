class SalespersonMailer < ApplicationMailer
  def welcome(user, password)
    @user = user
    @password = password
    @sign_in_url = new_user_session_url

    mail(
      to: user.email,
      subject: "Welcome to SupplierHub CRM — Your Login Details"
    )
  end
end
