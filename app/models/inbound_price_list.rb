class InboundPriceList < ApplicationRecord
  # Active Storage
  has_one_attached :pdf

  # No belongs_to — keyed by contact_email string, shared across orgs
  has_many :supplier_lists

  # Status constants
  STATUSES = %w[pending parsing parsed imported needs_review failed].freeze

  # Validations
  validates :contact_email, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :received_at, presence: true

  # Scopes
  scope :pending, -> { where(status: 'pending') }
  scope :parsing, -> { where(status: 'parsing') }
  scope :parsed, -> { where(status: 'parsed') }
  scope :failed, -> { where(status: 'failed') }
  scope :for_email, ->(email) { where(contact_email: email) }

  def self.latest_for(email)
    for_email(email).order(received_at: :desc).first
  end

  # Status checks
  def pending?
    status == 'pending'
  end

  def parsing?
    status == 'parsing'
  end

  def parsed?
    status == 'parsed'
  end

  def failed?
    status == 'failed'
  end

  def imported?
    status == 'imported'
  end

  def needs_review?
    status == 'needs_review'
  end

  # Find all email suppliers that match this price list's contact_email
  def matching_suppliers
    Supplier.email_suppliers.where(contact_email: contact_email)
  end

  # Cleanup: remove PDF blob and raw JSON to save storage
  def purge_storage!
    pdf.purge if pdf.attached?
    update!(raw_products_json: nil)
  end
end
