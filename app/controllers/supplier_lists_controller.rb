class SupplierListsController < ApplicationController
  before_action :require_organization!
  before_action :require_location_context!
  before_action :set_supplier_list, only: %i[show sync]
  before_action :require_operator!, only: %i[sync sync_all]

  def index
    # This page is no longer the primary UI — redirect to credentials page.
    # Individual supplier list show pages are still accessible directly.
    redirect_to supplier_credentials_path
  end

  def show
    @items = @supplier_list.supplier_list_items.by_position.includes(:supplier_product)
  end

  def sync
    # force: true — user explicitly clicked "Sync" on this list, bypass freshness check
    ImportSupplierListsJob.perform_later(@supplier_list.supplier_credential_id, force: true)
    @supplier_list.update(sync_status: 'syncing')

    redirect_to supplier_credentials_path, notice: "Syncing #{@supplier_list.supplier.name} order guides..."
  end

  def sync_all
    # Pick ONE credential per supplier to avoid redundant scraping.
    # Multiple users in the same org may have credentials for the same supplier —
    # syncing both would hit the supplier twice for identical data.
    credentials = scoped_credentials.active.includes(:supplier)
    one_per_supplier = credentials.group_by(&:supplier_id).map { |_, creds| creds.first }

    one_per_supplier.each_with_index do |credential, index|
      ImportSupplierListsJob.set(wait: (index * 10).seconds).perform_later(credential.id)
    end

    redirect_to supplier_credentials_path, notice: "Syncing all supplier order guides..."
  end

  private

  def set_supplier_list
    @supplier_list = scoped_supplier_lists.find(params[:id])
  end

  def current_organization_aggregated_lists
    if current_user.current_organization
      AggregatedList.for_organization(current_user.current_organization)
    else
      current_user.created_aggregated_lists
    end
  end
end
