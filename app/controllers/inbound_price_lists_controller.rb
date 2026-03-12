class InboundPriceListsController < ApplicationController
  before_action :require_operator!
  before_action :require_location_context!
  before_action :set_email_supplier
  before_action :set_price_list, only: [:show, :status, :review, :import]

  # GET /email_suppliers/:email_supplier_id/price_lists/:id
  def show
    # Status/waiting page while PDF is being parsed
  end

  # GET /email_suppliers/:email_supplier_id/price_lists/:id/status.json
  def status
    render json: {
      status: @price_list.status,
      product_count: @price_list.product_count,
      error_message: @price_list.error_message,
      redirect_to: @price_list.parsed? ? review_email_supplier_price_list_path(@email_supplier, @price_list) : nil
    }
  end

  # POST /email_suppliers/:email_supplier_id/price_lists/upload
  def upload
    file = params[:pdf]

    unless file.present?
      redirect_to supplier_credentials_path, alert: "Please select a PDF file to upload."
      return
    end

    unless file.content_type == 'application/pdf'
      redirect_to supplier_credentials_path, alert: "Please upload a PDF file."
      return
    end

    if file.size > 20.megabytes
      redirect_to supplier_credentials_path, alert: "File must be under 20MB."
      return
    end

    # Compute content hash for dedup
    pdf_binary = file.read
    file.rewind
    content_hash = Digest::SHA256.hexdigest(pdf_binary)

    # Check for existing parse of this exact PDF
    existing = InboundPriceList.find_by(
      contact_email: @email_supplier.contact_email,
      pdf_content_hash: content_hash
    )

    if existing&.parsed?
      redirect_to review_email_supplier_price_list_path(@email_supplier, existing),
                  notice: "This PDF has already been parsed. Review the results below."
      return
    end

    if existing && existing.status.in?(%w[pending parsing])
      redirect_to email_supplier_price_list_path(@email_supplier, existing),
                  notice: "This PDF is currently being processed."
      return
    end

    # Create new record
    price_list = InboundPriceList.create!(
      contact_email: @email_supplier.contact_email,
      received_at: Time.current,
      pdf_file_name: file.original_filename,
      pdf_content_hash: content_hash,
      status: 'pending'
    )
    price_list.pdf.attach(file)

    ParsePriceListJob.perform_later(price_list.id)

    redirect_to email_supplier_price_list_path(@email_supplier, price_list),
                notice: "PDF uploaded. Parsing now — this usually takes 15-30 seconds."
  end

  # GET /email_suppliers/:email_supplier_id/price_lists/:id/review
  def review
    unless @price_list.parsed?
      redirect_to email_supplier_price_list_path(@email_supplier, @price_list)
      return
    end

    @products = @price_list.raw_products_json['products'] || []
    @categories = @products.group_by { |p| p['category'] || 'Uncategorized' }

    # Load existing items for price change comparison (by SKU and by name)
    existing_list = SupplierList.find_by(
      supplier: @email_supplier,
      organization: current_user.current_organization
    )
    if existing_list
      items = existing_list.supplier_list_items.to_a
      @existing_items_by_sku = items.index_by(&:sku)
      @existing_items_by_name = items.index_by { |i| i.name.to_s.downcase.strip }
    else
      @existing_items_by_sku = {}
      @existing_items_by_name = {}
    end
  end

  # POST /email_suppliers/:email_supplier_id/price_lists/:id/import
  def import
    products = (params[:products] || []).select { |p| p[:included] == '1' }

    if products.empty?
      redirect_to review_email_supplier_price_list_path(@email_supplier, @price_list),
                  alert: "No products selected for import."
      return
    end

    result = ImportEmailPriceListService.new(
      @price_list,
      @email_supplier,
      products.map { |p| p.permit(:sku, :name, :price, :pack_size, :category, :included).to_h },
      current_location
    ).call

    if result[:errors].any?
      flash[:warning] = "Imported with #{result[:errors].size} errors. #{result[:items_imported]} new, #{result[:items_updated]} updated."
    else
      flash[:notice] = "Imported #{result[:items_imported] + result[:items_updated]} products from #{@email_supplier.name}."
    end

    redirect_to supplier_credentials_path
  end

  private

  def set_email_supplier
    @email_supplier = Supplier.email_suppliers
                              .where(organization: current_user.current_organization)
                              .find(params[:email_supplier_id])
  end

  def set_price_list
    @price_list = InboundPriceList.find(params[:id])
    unless @price_list.contact_email == @email_supplier.contact_email
      redirect_to supplier_credentials_path, alert: "Price list not found."
    end
  end
end
