module Webhooks
  class StripeController < ApplicationController
    skip_before_action :verify_authenticity_token
    skip_before_action :authenticate_user!

    def create
      payload = request.body.read
      sig_header = request.env["HTTP_STRIPE_SIGNATURE"]
      webhook_secret = Rails.application.config.stripe_webhook_secret

      begin
        unless webhook_secret.present?
          Rails.logger.error "[Stripe Webhook] No webhook secret configured — rejecting request"
          render json: { error: "Webhook secret not configured" }, status: :forbidden
          return
        end

        event = Stripe::Webhook.construct_event(payload, sig_header, webhook_secret)
      rescue JSON::ParserError => e
        Rails.logger.error "[Stripe Webhook] JSON parse error: #{e.message}"
        render json: { error: "Invalid payload" }, status: :bad_request
        return
      rescue Stripe::SignatureVerificationError => e
        Rails.logger.error "[Stripe Webhook] Signature verification failed: #{e.message}"
        render json: { error: "Invalid signature" }, status: :bad_request
        return
      end

      # Process the event
      result = Stripe::WebhookHandler.handle(event)

      case result[:status]
      when :success, :already_processed, :ignored
        render json: { status: result[:status] }, status: :ok
      when :user_not_found, :subscription_not_found
        Rails.logger.warn "[Stripe Webhook] #{result[:status]} for event #{event.id}"
        render json: { status: result[:status] }, status: :ok
      when :error
        Rails.logger.error "[Stripe Webhook] Error: #{result[:message]}"
        render json: { error: result[:message] }, status: :unprocessable_entity
      else
        render json: { status: "processed" }, status: :ok
      end
    end
  end
end
