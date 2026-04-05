class FeedbackMailer < ApplicationMailer
  def feedback_received(user:, category:, message:, file_data: [])
    @user = user
    @category = category.titleize
    @message = message
    @organization = user.current_organization
    @has_attachments = file_data.any?

    file_data.each do |file|
      attachments[file[:filename]] = Base64.strict_decode64(file[:content])
    end

    mail(
      to: "carmin@las-noches.com",
      subject: "SupplierHub Feedback: #{@category} from #{@user.email}"
    )
  end
end
