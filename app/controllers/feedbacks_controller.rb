class FeedbacksController < ApplicationController
  before_action :authenticate_user!

  def create
    category = params.dig(:feedback, :category)
    message = params.dig(:feedback, :message)&.strip

    if message.blank?
      render json: { error: "Message can't be blank" }, status: :unprocessable_entity
      return
    end

    uploaded_files = Array(params.dig(:feedback, :attachments)).reject(&:blank?)

    # Read files now — UploadedFile objects can't be serialized by Active Job
    file_data = uploaded_files.map do |file|
      { filename: file.original_filename, content: Base64.strict_encode64(file.read) }
    end

    FeedbackMailer.feedback_received(
      user: current_user,
      category: category,
      message: message,
      file_data: file_data
    ).deliver_now

    render json: { success: true }
  end
end
