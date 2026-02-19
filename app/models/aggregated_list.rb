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

  # Scopes
  scope :for_organization, ->(org) { where(organization: org) }
  scope :matched, -> { where(match_status: 'matched') }

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
end
