class SupplierList < ApplicationRecord
  # Associations
  belongs_to :supplier_credential
  belongs_to :supplier
  belongs_to :organization, optional: true
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
end
