class TwoFactorMailer < ApplicationMailer
  def code_required(two_fa_request)
    @request = two_fa_request
    @user = two_fa_request.user
    @supplier = two_fa_request.supplier_credential.supplier
    mail(to: @user.email, subject: "2FA Code Required for #{@supplier.name}")
  end
end
