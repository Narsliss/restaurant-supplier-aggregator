# Tracks a user's progress through the role-specific onboarding wizard
# (the spotlight tour mounted in the application layout).
#
# Records ONLY:
# - current step name
# - which steps the user has clicked through
# - lifecycle timestamps (started, completed, dismissed)
# - restart count
#
# Does NOT touch any application data (orgs, locations, suppliers, orders, etc.).
# All real DB writes during a wizard run go through the existing controllers
# the wizard surfaces — this model only knows where in the tour the user is.
class OnboardingProgress < ApplicationRecord
  belongs_to :user

  ROLES = %w[owner manager chef].freeze
  WELCOME_STEP = "welcome".freeze
  DONE_STEP    = "done".freeze

  validates :role, presence: true, inclusion: { in: ROLES }
  validates :current_step, presence: true
  validates :user_id, uniqueness: true
  validates :restart_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  before_validation :set_started_at, on: :create

  scope :active, -> { where(dismissed_at: nil, completed_at: nil) }

  # --- Class methods ---

  # Determine which wizard role applies to a user, or nil if the user
  # shouldn't see a wizard at all (super_admin, salesperson, no membership).
  def self.role_for(user)
    return nil if user.nil?
    return nil if user.super_admin?
    return nil if user.salesperson?

    org = user.current_organization
    # Brand-new user pre-org-create lands in the owner flow (they'll be the one creating it).
    return "owner" if org.nil?

    membership = user.membership_for(org)
    return nil unless membership&.active?

    case membership.role
    when "owner"   then "owner"
    when "manager" then "manager"
    when "chef"    then "chef"
    end
  end

  # Find or build (does NOT save) the progress record for a user.
  # Returns nil if the user shouldn't see a wizard.
  def self.for_user(user)
    role = role_for(user)
    return nil unless role

    find_by(user_id: user.id) || new(user: user, role: role)
  end

  # --- Predicates ---

  def in_progress?
    completed_at.nil? && dismissed_at.nil?
  end

  def dismissed?
    dismissed_at.present?
  end

  def completed?
    completed_at.present?
  end

  # --- Mutations ---

  # Advance the wizard to a new step. The previous step (unless welcome)
  # is appended to completed_steps. No-op if already completed/dismissed.
  def advance_to!(next_step)
    return false if completed? || dismissed?
    return false if next_step.blank?

    transaction do
      mark_step_complete(current_step) unless current_step == WELCOME_STEP
      self.current_step = next_step.to_s
      save!
    end
    true
  end

  # Mark the wizard finished. Final step name is recorded so the UI knows
  # to render the "all done" state.
  def complete!
    return false if dismissed?

    transaction do
      mark_step_complete(current_step) unless current_step == WELCOME_STEP || current_step == DONE_STEP
      self.current_step  = DONE_STEP
      self.completed_at  = Time.current
      save!
    end
    true
  end

  # Dismiss the wizard without completing it ("Skip for now"). The user can
  # resume later via the Restart Tour menu link.
  def dismiss!
    update!(dismissed_at: Time.current)
  end

  # Reset to the first step. Increments restart_count for telemetry.
  def restart!
    update!(
      current_step: WELCOME_STEP,
      completed_steps: [],
      completed_at: nil,
      dismissed_at: nil,
      started_at: Time.current,
      restart_count: restart_count + 1,
    )
  end

  # --- Computed state ---

  # Steps the wizard treats as "already done" based on real DB state, so
  # users who completed setup outside the wizard don't get asked to redo it.
  # READS ONLY — never writes.
  def computed_completed_steps
    steps = []
    org = user.current_organization

    case role
    when "owner"
      steps << "organization" if org.present?
      steps << "restaurant"   if org&.locations&.any?
      steps << "team"         if org && team_step_done?(org)
      steps << "suppliers"    if user.supplier_credentials.where(status: "active").any?
      steps << "promote"      if org&.aggregated_lists&.where(promoted_org_wide: true)&.any?
    when "chef"
      steps << "suppliers"    if user.supplier_credentials.where(status: "active").any?
    when "manager"
      # Manager flow is pure view/training — no real-state setup steps.
    end

    steps
  end

  # Click-through completed steps merged with computed-real-state completed steps.
  def effective_completed_steps
    (Array(completed_steps).map(&:to_s) + computed_completed_steps).uniq
  end

  private

  def set_started_at
    self.started_at ||= Time.current
  end

  def mark_step_complete(step)
    return if step.blank?
    self.completed_steps = (Array(completed_steps).map(&:to_s) + [step.to_s]).uniq
  end

  def team_step_done?(org)
    org.memberships.where(active: true).count > 1 ||
      org.organization_invitations.pending.any?
  end
end
