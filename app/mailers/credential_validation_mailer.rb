class CredentialValidationMailer < ApplicationMailer
  def validation_failed(supplier_credential)
    @credential = supplier_credential
    @user = supplier_credential.user
    @supplier = supplier_credential.supplier
    mail(to: @user.email, subject: "#{@supplier.name} Login Failed - Please Update Credentials")
  end

  def validation_result(supplier_credential, result)
    @credential = supplier_credential
    @user = supplier_credential.user
    @supplier = supplier_credential.supplier
    @result = result

    subject = if result[:valid]
                "#{@supplier.name} Credentials Verified Successfully"
              else
                "#{@supplier.name} Credential Validation Failed"
              end

    mail(to: @user.email, subject: subject)
  end
end
