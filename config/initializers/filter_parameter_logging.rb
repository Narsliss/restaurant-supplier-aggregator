# frozen_string_literal: true

# Configure parameters to be partially matched (e.g. passw matches password)
# and filtered from the log file. Use this to limit dissemination of
# temporary credentials, secrets, passwords, and other sensitive data.
Rails.application.config.filter_parameters += %i[
  passw
  secret
  token
  _key
  crypt
  salt
  certificate
  otp
  ssn
  password
  password_confirmation
]
