module Orders
  class EmailOrderPlacementService
    attr_reader :order

    def initialize(order)
      @order = order
    end

    def place_order
      validate_order!

      order.update!(status: 'processing')

      # Skip verification for email suppliers
      order.skip_verification!("Email supplier — no online verification available")

      # Generate order PDF
      pdf_data = Orders::OrderPdfGenerator.new(order).generate

      # Determine if we should actually send the email
      if should_send_email?
        SupplierOrderMailer.order_email(order, pdf_data).deliver_now

        confirmation_number = "EMAIL-#{Time.current.strftime('%Y%m%d%H%M%S')}-#{order.id}"
        order.update!(
          status: 'submitted',
          confirmation_number: confirmation_number,
          submitted_at: Time.current,
          total_amount: order.calculated_subtotal
        )
        order.order_items.update_all(status: 'added')

        Rails.logger.info "[EmailOrderPlacement] Order #{order.id} emailed to #{order.supplier.contact_email}"
      else
        # Dry run — generate PDF but don't send email
        confirmation_number = "EMAIL-DRY-#{Time.current.strftime('%Y%m%d%H%M%S')}-#{order.id}"
        order.update!(
          status: 'dry_run_complete',
          confirmation_number: confirmation_number,
          submitted_at: Time.current,
          total_amount: order.calculated_subtotal,
          notes: [order.notes, "[DRY RUN] Order PDF generated but email not sent. checkout_enabled=#{order.supplier.checkout_enabled?}"].compact.join("\n\n")
        )
        order.order_items.update_all(status: 'pending')

        Rails.logger.info "[EmailOrderPlacement] Order #{order.id} DRY RUN (email not sent)"
      end

      { success: true, order: order.reload }
    rescue StandardError => e
      order.update!(
        status: 'failed',
        notes: [order.notes, "Email order failed: #{e.message}"].compact.join("\n\n")
      )
      Rails.logger.error "[EmailOrderPlacement] Order #{order.id} failed: #{e.class}: #{e.message}"

      { success: false, error: e.message, order: order.reload }
    end

    private

    def validate_order!
      raise "No items in order" if order.order_items.empty?
      raise "Supplier has no contact email" if order.supplier.contact_email.blank?
    end

    def should_send_email?
      return false unless Rails.env.production?
      order.supplier.checkout_enabled?
    end
  end
end
