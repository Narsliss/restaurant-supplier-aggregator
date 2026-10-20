module ApplicationHelper
  # See config/initializers/support_email.rb.
  def support_email
    Rails.configuration.x.support_email
  end
end
