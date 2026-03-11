class SupplierList < ApplicationRecord
  # Associations
  belongs_to :supplier_credential
  belongs_to :supplier
  belongs_to :organization, optional: true
  belongs_to :location, optional: true
  has_many :supplier_list_items, dependent: :destroy
  has_many :aggregated_list_mappings, dependent: :destroy
  has_many :aggregated_lists, through: :aggregated_list_mappings

  # Validations
  validates :name, presence: true
  validates :list_type, inclusion: { in: %w[order_guide custom favorites managed] }
  validates :sync_status, inclusion: { in: %w[pending syncing synced failed] }

  # Scopes
  scope :synced, -> { where(sync_status: 'synced') }
  scope :failed, -> { where(sync_status: 'failed') }
  scope :needs_sync, -> { where(sync_status: %w[pending failed]) }
  scope :for_supplier, ->(supplier) { where(supplier: supplier) }
  scope :for_organization, ->(org) { where(organization: org) }
  scope :for_location, ->(loc) { where(location: loc) }

  # Auto-set location from credential
  before_validation :set_location_from_credential, on: :create

  # Auto-add to the location's master matched list when created
  after_create_commit :auto_add_to_matched_list

  # Delegations
  delegate :user, to: :supplier_credential

  # Status methods
  def synced?
    sync_status == 'synced'
  end

  def syncing?
    sync_status == 'syncing'
  end

  def failed?
    sync_status == 'failed'
  end

  def mark_syncing!
    update!(sync_status: 'syncing', sync_error: nil)
  end

  def mark_synced!
    update!(
      sync_status: 'synced',
      sync_error: nil,
      last_synced_at: Time.current,
      product_count: supplier_list_items.count
    )
  end

  def mark_failed!(error)
    update!(sync_status: 'failed', sync_error: error)
  end

  def refresh_product_count!
    update_column(:product_count, supplier_list_items.count)
  end

  def stale?
    last_synced_at.nil? || last_synced_at < 24.hours.ago
  end

  def time_since_sync
    return 'Never' unless last_synced_at

    distance = Time.current - last_synced_at
    if distance < 1.hour
      "#{(distance / 60).round}m ago"
    elsif distance < 24.hours
      "#{(distance / 3600).round}h ago"
    else
      "#{(distance / 86_400).round}d ago"
    end
  end

  private

  def set_location_from_credential
    self.location_id ||= supplier_credential&.location_id
  end

  # Automatically link this supplier list to the location's master matched list.
  # The matched list is the "all suppliers" view — every supplier list at the
  # location should be in it. Order lists handle curation/subsetting.
  def auto_add_to_matched_list
    return unless location_id && organization_id

    matched_list = AggregatedList.find_by(
      location_id: location_id,
      organization_id: organization_id,
      list_type: %w[master matched]
    )
    return unless matched_list

    unless matched_list.supplier_list_ids.include?(id)
      matched_list.aggregated_list_mappings.create!(supplier_list_id: id)
      Rails.logger.info "[AutoAdd] Added supplier list #{id} (#{name}) to matched list #{matched_list.id} (#{matched_list.name})"

      # Kick off incremental matching so new items appear in product matches
      SyncNewProductsJob.perform_later(matched_list.id)
    end
  end
end
