# Where customers write for help. Shown in the app (dashboard, Subscription
# page, Terms) and used as the reply-to on billing emails, which tell the
# owner to "just reply". Change it here, or set SUPPORT_EMAIL on both Railway
# services.
Rails.application.config.x.support_email = ENV.fetch("SUPPORT_EMAIL", "carmin@las-noches.com")
