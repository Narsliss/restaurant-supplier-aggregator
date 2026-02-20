class SupplierListsController < ApplicationController
  before_action :set_supplier_list, only: %i[show sync]

  def index
    @supplier_lists = current_organization_lists
                      .includes(:supplier, :supplier_credential)
                      .order('suppliers.name ASC, supplier_lists.name ASC')

    @lists_by_supplier = @supplier_lists.group_by(&:supplier)
    @credentials = current_user.supplier_credentials.active.includes(:supplier)

    # Detect if a sync is still in progress.
    # Show the banner whenever any list is actively syncing OR the syncing param
    # was recently set (covers the brief window before the job marks lists as syncing).
    has_syncing_lists = @supplier_lists.where(sync_status: 'syncing').exists?
    if params[:syncing].present?
      sync_started = Time.at(params[:syncing].to_i) rescue nil
      recently_started = sync_started && sync_started > 5.minutes.ago
      @syncing = has_syncing_lists || (recently_started && @lists_by_supplier.empty?)
    else
      @syncing = has_syncing_lists
    end

    # Comparison lists (AggregatedLists)
    @aggregated_lists = current_organization_aggregated_lists
                          .includes(supplier_lists: :supplier)
                          .order(updated_at: :desc)
    @lists_by_supplier_for_form = @supplier_lists.group_by(&:supplier)
  end

  def show
    @items = @supplier_list.supplier_list_items.by_position.includes(:supplier_product)
  end

  def sync
    ImportSupplierListsJob.perform_later(@supplier_list.supplier_credential_id)
    @supplier_list.update(sync_status: 'syncing')

    respond_to do |format|
      format.html { redirect_to supplier_lists_path(syncing: Time.current.to_i), notice: "Syncing #{@supplier_list.supplier.name} lists..." }
      format.turbo_stream
    end
  end

  def sync_all
    credentials = current_user.supplier_credentials.active
    credentials.each_with_index do |credential, index|
      ImportSupplierListsJob.set(wait: (index * 10).seconds).perform_later(credential.id)
    end

    redirect_to supplier_lists_path(syncing: Time.current.to_i), notice: "Syncing lists for #{credentials.count} suppliers..."
  end

  private

  def set_supplier_list
    @supplier_list = current_organization_lists.find(params[:id])
  end

  def current_organization_lists
    if current_user.current_organization
      SupplierList.for_organization(current_user.current_organization)
    else
      SupplierList.joins(:supplier_credential).where(supplier_credentials: { user_id: current_user.id })
    end
  end

  def current_organization_aggregated_lists
    if current_user.current_organization
      AggregatedList.for_organization(current_user.current_organization)
    else
      current_user.created_aggregated_lists
    end
  end
end
