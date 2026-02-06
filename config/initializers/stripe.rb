# Stripe configuration
Rails.application.config.to_prepare do
  Stripe.api_key = ENV.fetch("STRIPE_SECRET_KEY", nil)
end

# Stripe API version
Stripe.api_version = "2024-12-18.acacia"

# Configure webhook signing for security
Rails.application.config.stripe_webhook_secret = ENV.fetch("STRIPE_WEBHOOK_SECRET", nil)

# Subscription configuration
Rails.application.config.stripe_config = {
  # Monthly subscription price
  monthly_price_id: ENV.fetch("STRIPE_MONTHLY_PRICE_ID", nil),
  monthly_amount: 9900, # $99.00 in cents

  # Trial period (optional)
  trial_days: ENV.fetch("STRIPE_TRIAL_DAYS", 14).to_i,

  # Product name
  product_name: "SupplierHub Pro",

  # Success and cancel URLs for checkout
  success_url: ENV.fetch("STRIPE_SUCCESS_URL", "/subscription/success"),
  cancel_url: ENV.fetch("STRIPE_CANCEL_URL", "/subscription/cancel")
}.freeze
