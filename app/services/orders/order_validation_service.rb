module Orders
  class OrderValidationService
    class ValidationError < StandardError
      attr_reader :errors, :warnings

      def initialize(errors: [], warnings: [])
        @errors = errors
        @warnings = warnings
        super(errors.map { |e| e[:message] }.join("; "))
      end
    end

    attr_reader :order, :errors, :warnings

    def initialize(order)
      @order = order
      @errors = []
      @warnings = []
    end

    def validate!
      run_validations

      if errors.any?
        raise ValidationError.new(errors: errors, warnings: warnings)
      end

      { valid: true, warnings: warnings }
    end

    def valid?
      run_validations
      errors.empty?
    end

    private

    def run_validations
      @errors = []
      @warnings = []

      # Item availability first — may remove OOS items, changing the total
      validate_item_availability
      validate_order_minimum
      validate_item_minimums
      validate_item_maximums
      validate_delivery_schedule
      validate_cutoff_time
      validate_account_status
      validate_price_changes

      log_validations
    end

    def validate_order_minimum
      requirement = supplier_requirement("order_minimum")
      return unless requirement

      minimum = requirement.numeric_value
      current_total = order.calculated_subtotal

      if current_total < minimum
        difference = minimum - current_total
        add_error(
          type: "order_minimum",
          message: requirement.formatted_error_message(
            current_total: format_currency(current_total),
            minimum: format_currency(minimum),
            difference: format_currency(difference)
          ),
          details: {
            minimum: minimum,
            current_total: current_total,
            difference: difference
          }
        )
      end
    end

    def validate_item_minimums
      order.order_items.includes(:supplier_product).each do |item|
        sp = item.supplier_product
        next unless sp.minimum_quantity && sp.minimum_quantity > 1

        unless sp.meets_minimum?(item.quantity)
          add_error(
            type: "item_minimum",
            message: "#{sp.supplier_name} requires a minimum quantity of #{sp.minimum_quantity}. You ordered #{item.quantity.to_i}.",
            details: {
              product_id: sp.id,
              product_name: sp.supplier_name,
              minimum: sp.minimum_quantity,
              ordered: item.quantity
            }
          )
        end
      end
    end

    def validate_item_maximums
      order.order_items.includes(:supplier_product).each do |item|
        sp = item.supplier_product
        next unless sp.maximum_quantity

        unless sp.within_maximum?(item.quantity)
          add_error(
            type: "item_maximum",
            message: "#{sp.supplier_name} has a maximum order quantity of #{sp.maximum_quantity}. You ordered #{item.quantity.to_i}.",
            details: {
              product_id: sp.id,
              product_name: sp.supplier_name,
              maximum: sp.maximum_quantity,
              ordered: item.quantity
            }
          )
        end
      end
    end

    def validate_item_availability
      unavailable_items = order.order_items.joins(:supplier_product)
        .where(supplier_products: { in_stock: false })
        .includes(:supplier_product)

      return if unavailable_items.empty?

      # If ALL items are unavailable, error — nothing to order
      if unavailable_items.count == order.order_items.count
        unavailable_items.each do |item|
          add_error(
            type: "item_unavailable",
            message: "#{item.supplier_product.supplier_name} is currently out of stock.",
            details: { product_id: item.supplier_product.id, product_name: item.supplier_product.supplier_name }
          )
        end
        return
      end

      # Some items available — auto-remove the unavailable ones and continue
      removed_names = unavailable_items.map { |i| i.supplier_product.supplier_name }
      unavailable_items.destroy_all

      add_warning(
        type: "items_removed",
        message: "Removed #{removed_names.size} out-of-stock item#{'s' if removed_names.size > 1}: #{removed_names.join(', ')}",
        details: { removed_items: removed_names }
      )
    end

    def validate_delivery_schedule
      schedules = order.supplier.delivery_schedule_for(order.location)
      return if schedules.empty?

      next_delivery = schedules.min_by(&:next_delivery_date)&.next_delivery_date

      if next_delivery.nil?
        add_warning(
          type: "no_delivery",
          message: "No delivery schedule found for your location from #{order.supplier.name}.",
          details: { supplier: order.supplier.name }
        )
      end
    end

    def validate_cutoff_time
      schedules = order.supplier.delivery_schedule_for(order.location)
      schedule = schedules.first
      return unless schedule

      if schedule.past_cutoff?
        add_error(
          type: "cutoff_passed",
          message: "Order cutoff time has passed. Orders for #{order.supplier.name} must be placed by #{schedule.cutoff_time.strftime('%I:%M %p')} on #{schedule.cutoff_day_name}.",
          details: {
            cutoff_time: schedule.next_cutoff_datetime,
            current_time: Time.current
          }
        )
      elsif schedule.cutoff_approaching?
        add_warning(
          type: "cutoff_approaching",
          message: "Order cutoff is approaching! You have #{format_time_remaining(schedule.time_until_cutoff)} to place this order for next delivery.",
          details: {
            cutoff_time: schedule.next_cutoff_datetime,
            time_remaining: schedule.time_until_cutoff
          }
        )
      end
    end

    def validate_account_status
      credential = order.user.supplier_credentials.find_by(supplier: order.supplier)

      unless credential&.active?
        add_error(
          type: "account_inactive",
          message: "Your #{order.supplier.name} account is not active. Please verify your credentials.",
          details: { status: credential&.status }
        )
        return
      end

      if credential.on_hold?
        add_error(
          type: "account_hold",
          message: "Your #{order.supplier.name} account has a hold. Please contact #{order.supplier.name} to resolve. Reason: #{credential.hold_reason}",
          details: { hold_reason: credential.hold_reason }
        )
      end
    end

    def validate_price_changes
      price_changes = []

      order.order_items.includes(:supplier_product).each do |item|
        sp = item.supplier_product

        if item.price_changed?
          change_pct = ((sp.current_price - item.unit_price) / item.unit_price * 100).round(2)

          price_changes << {
            product_name: sp.supplier_name,
            old_price: item.unit_price,
            new_price: sp.current_price,
            change_percent: change_pct
          }
        end
      end

      if price_changes.any?
        total_old = price_changes.sum { |pc| pc[:old_price] }
        total_new = price_changes.sum { |pc| pc[:new_price] }

        add_warning(
          type: "price_changed",
          message: "#{price_changes.count} item(s) have changed price since you created this order. Review changes before submitting.",
          details: {
            changes: price_changes,
            total_difference: total_new - total_old
          }
        )
      end
    end

    def supplier_requirement(type)
      order.supplier.supplier_requirements.find_by(
        requirement_type: type,
        active: true
      )
    end

    def add_error(type:, message:, details: {})
      @errors << { type: type, message: message, details: details, blocking: true }
    end

    def add_warning(type:, message:, details: {})
      @warnings << { type: type, message: message, details: details, blocking: false }
    end

    def format_currency(amount)
      "$#{'%.2f' % amount}"
    end

    def format_time_remaining(seconds)
      minutes = (seconds / 60).to_i
      if minutes >= 60
        hours = minutes / 60
        mins = minutes % 60
        "#{hours}h #{mins}m"
      else
        "#{minutes} minutes"
      end
    end

    def log_validations
      (@errors + @warnings).each do |validation|
        OrderValidation.create!(
          order: order,
          validation_type: validation[:type],
          passed: !validation[:blocking],
          message: validation[:message],
          details: validation[:details],
          validated_at: Time.current
        )
      end
    end
  end
end
