class ParsePriceListJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: 30.seconds, attempts: 2

  def perform(inbound_price_list_id)
    price_list = InboundPriceList.find(inbound_price_list_id)
    return if price_list.parsed? # Idempotency guard

    PdfParsingService.new(price_list).call
  end
end
