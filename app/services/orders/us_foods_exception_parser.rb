module Orders
  # Turns a US Foods order payload (as returned by the order-domain-api,
  # read-only) into a normalized list of post-submission exceptions. Pure —
  # no DB, no network — so it's easy to test against captured fixtures.
  #
  # Normalized exception shape:
  #   { sku:, type:, ordered:, filled:, message: }
  # type ∈ out_of_stock | short_fill | substituted | removed | price_change | other
  class UsFoodsExceptionParser
    def self.parse(order)
      new(order).parse
    end

    def initialize(order)
      @order = order.is_a?(Hash) ? order : {}
    end

    def parse
      exceptions = []
      exceptions.concat(order_level_exceptions)
      exceptions.concat(line_level_exceptions)
      exceptions.concat(price_change_exception)
      exceptions.uniq
    end

    private

    def order_level_exceptions
      out = []
      Array(@order['orderExceptions']).each do |ex|
        next unless ex.is_a?(Hash)

        out << { sku: str(ex['productNumber']), type: 'other', ordered: nil, filled: nil,
                 message: str(ex['description'] || ex['message'] || ex['reason'] || 'Order exception') }
      end
      Array(@order['errorDetails']).each do |ed|
        msg = ed.is_a?(Hash) ? (ed['message'] || ed['description'] || ed['errorText']) : ed
        out << { sku: nil, type: 'other', ordered: nil, filled: nil, message: str(msg || 'Error') }
      end
      out
    end

    def line_level_exceptions
      Array(@order['orderItems']).filter_map do |li|
        next unless li.is_a?(Hash)

        sku = str(li['productNumber'] || li['itemNumber'] || li['sku'])
        ordered = int(li['unitsOrdered'] || li['eachesOrdered'])
        accepted = li['quantityAccepted'] || li['unitsReserved'] || li['eachesReserved']
        accepted = accepted.nil? ? nil : accepted.to_i

        if truthy(li['tandemDeleted'])
          { sku: sku, type: 'removed', ordered: ordered, filled: 0, message: 'Removed by US Foods' }
        elsif truthy(li['substituteFlag']) || truthy(li['originalProductWasSubbed'])
          { sku: sku, type: 'substituted', ordered: ordered, filled: accepted, message: 'Substituted by US Foods' }
        elsif accepted && ordered.positive? && accepted < ordered
          if accepted.zero?
            { sku: sku, type: 'out_of_stock', ordered: ordered, filled: 0, message: 'Out of stock' }
          else
            { sku: sku, type: 'short_fill', ordered: ordered, filled: accepted,
              message: "Only #{accepted} of #{ordered} available" }
          end
        elsif int(li['productExceptionCount']).positive?
          { sku: sku, type: 'other', ordered: ordered, filled: accepted,
            message: "#{int(li['productExceptionCount'])} exception(s)" }
        end
      end
    end

    def price_change_exception
      return [] unless truthy(@order['priceChangeFlag'])

      [{ sku: nil, type: 'price_change', ordered: nil, filled: nil, message: 'Prices changed after submission' }]
    end

    def truthy(val)
      val == true || val.to_s.downcase == 'true' || val.to_s == '1'
    end

    def int(val)
      val.to_i
    end

    def str(val)
      val.nil? ? nil : val.to_s.strip.presence
    end
  end
end
