module Onboarding
  # JSON API for the onboarding wizard's client-side controller.
  # Reads/writes ONLY the user's onboarding_progress row — never any
  # application data.
  class ProgressController < ApplicationController
    # Wizard runs everywhere, including before subscription/onboarding gates
    # would normally fire (e.g. on the first dashboard load when no org exists).
    skip_before_action :ensure_onboarding_complete, raise: false
    skip_before_action :require_subscription,       raise: false

    before_action :load_progress

    # GET /onboarding/progress
    def show
      @progress.save! if @progress.new_record?
      render json: progress_payload
    end

    # POST /onboarding/progress/advance
    # Body: { next_step: "organization" }
    def advance
      next_step = params[:next_step].to_s
      if next_step.blank?
        render json: { error: "next_step is required" }, status: :unprocessable_entity
        return
      end

      @progress.save! if @progress.new_record?
      @progress.advance_to!(next_step)
      render json: progress_payload
    end

    # POST /onboarding/progress/complete
    def complete
      @progress.save! if @progress.new_record?
      @progress.complete!
      render json: progress_payload
    end

    # POST /onboarding/progress/skip
    def skip
      @progress.save! if @progress.new_record?
      @progress.dismiss!
      render json: progress_payload
    end

    # POST /onboarding/progress/restart
    # Supports JSON (called by JS controller) and HTML (called by Restart
    # Tour button in the avatar dropdown — redirects back so the wizard
    # mounts fresh on next page render).
    def restart
      @progress.save! if @progress.new_record?
      @progress.restart!

      respond_to do |format|
        format.json { render json: progress_payload }
        format.html { redirect_to(request.referer || root_path, notice: "Tour restarted.") }
      end
    end

    private

    def load_progress
      @progress = OnboardingProgress.for_user(current_user)
      head :no_content if @progress.nil?
    end

    def progress_payload
      {
        role:             @progress.role,
        current_step:     @progress.current_step,
        completed_steps:  @progress.effective_completed_steps,
        in_progress:      @progress.in_progress?,
        completed_at:     @progress.completed_at,
        dismissed_at:     @progress.dismissed_at,
        restart_count:    @progress.restart_count,
      }
    end
  end
end
