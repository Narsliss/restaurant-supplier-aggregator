class SupplierListsController < ApplicationController
  before_action :require_organization!
  before_action :require_location_context!
  before_action :set_supplier_list, only: %i[show sync]
  before_action :require_operator!, only: %i[sync sync_all]

  def index
    @supplier_lists = scoped_supplier_lists
                      .includes(:supplier, :supplier_credential)
                      .order('suppliers.name ASC, supplier_lists.name ASC')

    @lists_by_supplier = @supplier_lists.group_by(&:supplier)
    @credentials = scoped_credentials.active.includes(:supplier)
    @read_only = current_role == 'manager'

    # Detect if a sync is still in progress
    has_syncing_lists = @supplier_lists.where(sync_status: 'syncing').exists?

    credential_ids = @credentials.pluck(:id)
    pending_job_credential_ids = []
    if credential_ids.any?
      SolidQueue::Job
        .where(class_name: 'ImportSupplierListsJob', finished_at: nil)
        .where('created_at > ?', 30.minutes.ago)
        .pluck(:arguments)
        .each do |args|
          cred_id = (JSON.parse(args)["arguments"]&.first rescue nil)
          pending_job_credential_ids << cred_id if cred_id && credential_ids.include?(cred_id)
        end
    end
    has_pending_import_jobs = pending_job_credential_ids.any?

    actually_syncing = has_syncing_lists || has_pending_import_jobs

    if params[:syncing].present?
      if actually_syncing
        @syncing = true
      else
        # Sync was triggered via URL param but everything is done now.
        # Brief grace period in case the job hasn't been picked up yet.
        sync_started = Time.at(params[:syncing].to_i) rescue nil
        recently_started = sync_started && sync_started > 30.seconds.ago
        if recently_started
          @syncing = true
        else
          # Sync is done — redirect to clean URL so banner disappears
          # and auto-refresh stops.
          redirect_to supplier_lists_path, notice: "Supplier lists updated." and return
        end
      end
    else
      @syncing = actually_syncing
    end

    @syncing_credential_ids = Set.new(pending_job_credential_ids)
    @syncing_credential_ids += @supplier_lists.where(sync_status: 'syncing').pluck(:supplier_credential_id)

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
    # force: true — user explicitly clicked "Sync" on this list, bypass freshness check
    ImportSupplierListsJob.perform_later(@supplier_list.supplier_credential_id, force: true)
    @supplier_list.update(sync_status: 'syncing')

    redirect_to supplier_lists_path(syncing: Time.current.to_i)
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

    redirect_to supplier_lists_path(syncing: Time.current.to_i)
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
