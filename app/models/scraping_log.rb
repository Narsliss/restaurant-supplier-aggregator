# frozen_string_literal: true

# Tracks scraping/import operations for monitoring and debugging
class ScrapingLog < ApplicationRecord
  belongs_to :supplier
  belongs_to :supplier_credential, optional: true

  # Status values
  STATUSES = %w[pending running completed failed cancelled].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :supplier, presence: true

  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  scope :for_supplier, ->(supplier) { where(supplier: supplier) }
  scope :failed, -> { where(status: 'failed') }
  scope :completed, -> { where(status: 'completed') }
  scope :running, -> { where(status: 'running') }
  scope :in_last, ->(duration) { where('created_at > ?', duration.ago) }

  # Callbacks
  before_create :set_started_at, if: -> { started_at.blank? }

  # Class methods
  def self.last_for_supplier(supplier)
    for_supplier(supplier).recent.first
  end

  def self.success_rate_in_last(duration)
    logs = in_last(duration)
    return 0 if logs.count.zero?

    completed_count = logs.completed.count
    (completed_count.to_f / logs.count * 100).round(2)
  end

  # Instance methods
  def duration
    return nil unless started_at && completed_at

    completed_at - started_at
  end

  def duration_formatted
    return 'N/A' unless duration

    minutes = (duration / 60).to_i
    seconds = (duration % 60).to_i

    if minutes > 0
      "#{minutes}m #{seconds}s"
    else
      "#{seconds}s"
    end
  end

  def mark_completed!(product_count: nil, products_updated: nil)
    attrs = {
      status: 'completed',
      completed_at: Time.current,
      products_imported: product_count || products_imported
    }
    attrs[:products_updated] = products_updated if products_updated
    update!(attrs)
  end

  def mark_failed!(error_message, error_details = nil)
    update!(
      status: 'failed',
      completed_at: Time.current,
      error_message: error_message,
      error_details: error_details
    )
  end

  def mark_cancelled!
    update!(
      status: 'cancelled',
      completed_at: Time.current
    )
  end

  def running?
    status == 'running'
  end

  def completed?
    status == 'completed'
  end

  def failed?
    status == 'failed'
  end

  private

  def set_started_at
    self.started_at = Time.current
  end
end
