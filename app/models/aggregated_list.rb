class AggregatedList < ApplicationRecord
  # Associations
  belongs_to :organization, optional: true
  belongs_to :created_by, class_name: 'User'
  has_many :aggregated_list_mappings, dependent: :destroy
  has_many :supplier_lists, through: :aggregated_list_mappings
  has_many :product_matches, dependent: :destroy

  # Validations
  validates :name, presence: true, uniqueness: { scope: :organization_id }
  validates :match_status, inclusion: { in: %w[pending matching matched failed] }
  validates :list_type, inclusion: { in: %w[matched custom master] }
  validate :only_one_promoted_per_org, if: :promoted_org_wide?

  # Scopes
  scope :for_organization, ->(org) { where(organization: org) }
  scope :matched, -> { where(match_status: 'matched') }
  scope :matched_lists, -> { where(list_type: %w[matched master]) }
  scope :custom_lists, -> { where(list_type: 'custom') }
  scope :for_location, ->(loc) { where(location_id: loc.is_a?(Integer) ? loc : loc.id) }
  scope :promoted, -> { where(promoted_org_wide: true) }

  # List type methods
  def matched_list?
    list_type.in?(%w[matched master])
  end

  def custom_list?
    list_type == 'custom'
  end

  def promoted?
    promoted_org_wide?
  end

  # Status methods
  def matched?
    match_status == 'matched'
  end

  def matching?
    match_status == 'matching'
  end

  def pending?
    match_status == 'pending'
  end

  def mark_matching!
    update!(match_status: 'matching')
  end

  def mark_matched!
    update!(match_status: 'matched')
  end

  def mark_failed!
    update!(match_status: 'failed')
  end

  # Catalog search status
  def searching_catalog?
    catalog_search_status == 'searching'
  end

  def mark_searching_catalog!
    update!(catalog_search_status: 'searching')
  end

  def mark_catalog_search_done!
    update!(catalog_search_status: 'completed')
  end

  # Supplier info
  def suppliers
    supplier_lists.includes(:supplier).map(&:supplier).uniq
  end

  def supplier_count
    supplier_lists.select(:supplier_id).distinct.count
  end

  # Match stats
  def confirmed_count
    product_matches.where(match_status: 'confirmed').count
  end

  def auto_matched_count
    product_matches.where(match_status: 'auto_matched').count
  end

  def matched_product_count
    product_matches.where(match_status: %w[confirmed auto_matched manual]).count
  end

  def unmatched_count
    product_matches.where(match_status: 'unmatched').count
  end

  def total_match_count
    product_matches.count
  end

  def review_needed?
    auto_matched_count > 0 || unmatched_count > 0
  end

  private

  def only_one_promoted_per_org
    existing = self.class.where(organization_id: organization_id, promoted_org_wide: true)
                         .where.not(id: id)
    if existing.exists?
      errors.add(:promoted_org_wide, 'another list is already promoted for this organization')
    end
  end
end
