class CredentialValidationMailer < ApplicationMailer
  def validation_failed(supplier_credential)
    @credential = supplier_credential
    @user = supplier_credential.user
    @supplier = supplier_credential.supplier
    mail(to: @user.email, subject: "#{@supplier.name} Login Failed - Please Update Credentials")
  end
end
