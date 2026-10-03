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

    # Fields verified live on Alfio's order #332 (Oct 3 2026, delivered Sep 28):
    #   unitsOrdered/unitsReserved (cases), eachesOrdered/eachesReserved — the
    #     reserved counts are what US Foods will actually ship. The vinegar
    #     and chevre showed 1 ordered / 0 reserved ("Expected in-stock 9/29"
    #     in the USF app).
    #   quantityAccepted is a true/false FLAG, not a count. (We used to read it
    #     as a quantity; once true, .to_i crashed and the check gave up.)
    #   tandemDeleted is set on EVERY line once the order is archived after
    #     delivery (orderStatus TANDEM_DELETED), so it only means "removed"
    #     on an order that is still live.
    #   substituteFlag / originalProductWasSubbed are "" / "N" when not subbed.
    def line_level_exceptions
      return [] if @order['orderStatus'].to_s == 'DELETED' # an abandoned draft
      archived = @order['orderStatus'].to_s == 'TANDEM_DELETED'

      Array(@order['orderItems']).filter_map do |li|
        next unless li.is_a?(Hash)

        sku = str(li['productNumber'] || li['itemNumber'] || li['sku'])
        cases = int(li['unitsOrdered'])
        eaches = int(li['eachesOrdered'])
        ordered = cases.positive? ? cases : eaches
        reserved_raw = cases.positive? ? li['unitsReserved'] : li['eachesReserved']
        reserved = reserved_raw.nil? ? nil : reserved_raw.to_i
        unit = cases.positive? || eaches.zero? ? '' : ' each'

        if truthy(li['tandemDeleted']) && !archived
          { sku: sku, type: 'removed', ordered: ordered, filled: 0, message: 'Removed by US Foods' }
        elsif truthy(li['substituteFlag']) || truthy(li['originalProductWasSubbed'])
          { sku: sku, type: 'substituted', ordered: ordered, filled: reserved, message: 'Substituted by US Foods' }
        elsif reserved && ordered.positive? && reserved < ordered
          if reserved.zero?
            { sku: sku, type: 'out_of_stock', ordered: ordered, filled: 0,
              message: "Out of stock: 0 of #{ordered}#{unit} reserved" }
          else
            { sku: sku, type: 'short_fill', ordered: ordered, filled: reserved,
              message: "Only #{reserved} of #{ordered}#{unit} reserved" }
          end
        elsif int(li['productExceptionCount']).positive?
          { sku: sku, type: 'other', ordered: ordered, filled: reserved,
            message: "#{int(li['productExceptionCount'])} exception(s)" }
        end
      end
    end

    def price_change_exception
      return [] unless truthy(@order['priceChangeFlag'])

      [{ sku: nil, type: 'price_change', ordered: nil, filled: nil, message: 'Prices changed after submission' }]
    end

    def truthy(val)
      val == true || %w[true 1 y yes].include?(val.to_s.strip.downcase)
    end

    def int(val)
      val.is_a?(Numeric) || val.is_a?(String) ? val.to_i : 0
    end

    def str(val)
      val.nil? ? nil : val.to_s.strip.presence
    end
  end
end
