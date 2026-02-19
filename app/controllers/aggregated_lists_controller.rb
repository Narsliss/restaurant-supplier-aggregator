class AggregatedListsController < ApplicationController
  before_action :set_aggregated_list, only: %i[show edit update destroy run_matching]

  def show
    @supplier_lists = @aggregated_list.supplier_lists.includes(:supplier)
    @product_matches = @aggregated_list.product_matches
                                       .includes(product_match_items: %i[supplier supplier_list_item])
                                       .order(Arel.sql("CASE match_status WHEN 'confirmed' THEN 0 WHEN 'manual' THEN 1 WHEN 'auto_matched' THEN 2 WHEN 'unmatched' THEN 3 WHEN 'rejected' THEN 4 ELSE 5 END, position ASC"))
    @suppliers = @supplier_lists.map(&:supplier).uniq

    # Load all items per supplier for dropdown reassignment
    @items_by_supplier = {}
    @supplier_lists.each do |sl|
      @items_by_supplier[sl.supplier_id] = sl.supplier_list_items
                                             .select(:id, :name, :sku, :price, :pack_size)
                                             .order(:name)
    end
  end

  def new
    @aggregated_list = AggregatedList.new
    @available_lists = available_supplier_lists
  end

  def create
    @aggregated_list = AggregatedList.new(aggregated_list_params)
    @aggregated_list.organization = current_user.current_organization
    @aggregated_list.created_by = current_user

    if @aggregated_list.save
      # Connect selected supplier lists
      update_list_mappings

      # Trigger AI matching in background
      AiProductMatchJob.perform_later(@aggregated_list.id) if @aggregated_list.supplier_lists.count >= 2

      if params[:return_to] == "supplier_lists"
        redirect_to supplier_lists_path, notice: "#{@aggregated_list.name} created. Matching products..."
      else
        redirect_to @aggregated_list, notice: "#{@aggregated_list.name} created. Matching products..."
      end
    else
      if params[:return_to] == "supplier_lists"
        redirect_to supplier_lists_path, alert: @aggregated_list.errors.full_messages.join(", ")
      else
        @available_lists = available_supplier_lists
        render :new, status: :unprocessable_entity
      end
    end
  end

  def edit
    @available_lists = available_supplier_lists
    @selected_list_ids = @aggregated_list.supplier_list_ids
  end

  def update
    if @aggregated_list.update(aggregated_list_params)
      update_list_mappings
      # Re-run matching if lists changed
      AiProductMatchJob.perform_later(@aggregated_list.id) if @aggregated_list.supplier_lists.count >= 2

      redirect_to @aggregated_list, notice: "#{@aggregated_list.name} updated. Re-matching products..."
    else
      @available_lists = available_supplier_lists
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    name = @aggregated_list.name
    @aggregated_list.destroy
    redirect_to supplier_lists_path, notice: "#{name} deleted."
  end

  def run_matching
    @aggregated_list.update(match_status: 'matching')
    AiProductMatchJob.perform_later(@aggregated_list.id)
    redirect_to @aggregated_list, notice: 'Re-running product matching...'
  end

  private

  def set_aggregated_list
    @aggregated_list = current_organization_aggregated_lists.find(params[:id])
  end

  def current_organization_aggregated_lists
    if current_user.current_organization
      AggregatedList.for_organization(current_user.current_organization)
    else
      current_user.created_aggregated_lists
    end
  end

  def available_supplier_lists
    if current_user.current_organization
      SupplierList.for_organization(current_user.current_organization)
                  .includes(:supplier)
                  .order('suppliers.name ASC, supplier_lists.name ASC')
    else
      SupplierList.joins(:supplier_credential)
                  .where(supplier_credentials: { user_id: current_user.id })
                  .includes(:supplier)
    end
  end

  def aggregated_list_params
    params.require(:aggregated_list).permit(:name, :description)
  end

  def update_list_mappings
    return unless params[:supplier_list_ids]

    new_ids = params[:supplier_list_ids].reject(&:blank?).map(&:to_i)
    current_ids = @aggregated_list.supplier_list_ids

    # Remove deselected
    (current_ids - new_ids).each do |id|
      @aggregated_list.aggregated_list_mappings.find_by(supplier_list_id: id)&.destroy
    end

    # Add new
    (new_ids - current_ids).each do |id|
      @aggregated_list.aggregated_list_mappings.create(supplier_list_id: id)
    end
  end
end
