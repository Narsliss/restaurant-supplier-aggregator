require 'rails_helper'

RSpec.describe 'Onboarding wizard partial — layout integration', type: :request do
  describe 'eligible owner on the dashboard' do
    let(:user) { create(:user, :fully_onboarded) }
    before { sign_in user }

    it 'renders the wizard host div with role + step data attributes' do
      get root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="onboarding-wizard"')
      expect(response.body).to include('data-onboarding-wizard-role-value="owner"')
      expect(response.body).to include('data-onboarding-wizard-current-step-value="welcome"')
    end

    it 'includes endpoint URLs in data attributes' do
      get root_path
      expect(response.body).to include('data-onboarding-wizard-advance-url-value="/onboarding/progress/advance"')
      expect(response.body).to include('data-onboarding-wizard-skip-url-value="/onboarding/progress/skip"')
      expect(response.body).to include('data-onboarding-wizard-complete-url-value="/onboarding/progress/complete"')
    end

    it 'does NOT lazily create an OnboardingProgress row from rendering the partial' do
      expect {
        get root_path
      }.not_to change(OnboardingProgress, :count)
    end
  end

  describe 'super_admin user' do
    let(:user) { create(:user, :super_admin) }
    before { sign_in user }

    it 'omits the wizard partial entirely (admin redirects, but partial is suppressed)' do
      get root_path
      # Super admins bounce to admin root, but in case any page lands them
      # somewhere with the layout, the partial should never appear.
      expect(response.body).not_to include('data-controller="onboarding-wizard"')
    end
  end

  describe 'unauthenticated visitor' do
    it 'omits the wizard (Devise redirects to sign-in)' do
      get root_path
      expect(response).to redirect_to(new_user_session_path)
      follow_redirect!
      expect(response.body).not_to include('data-controller="onboarding-wizard"')
    end
  end

  describe 'after the user dismisses the wizard' do
    let(:user) { create(:user, :fully_onboarded) }
    before { sign_in user }

    it 'omits the partial on subsequent page loads' do
      OnboardingProgress.create!(user: user, role: 'owner', dismissed_at: Time.current)

      get root_path
      expect(response.body).not_to include('data-controller="onboarding-wizard"')
    end
  end

  describe 'after the user completes the wizard' do
    let(:user) { create(:user, :fully_onboarded) }
    before { sign_in user }

    it 'omits the partial on subsequent page loads' do
      OnboardingProgress.create!(user: user, role: 'owner', current_step: 'done', completed_at: Time.current)

      get root_path
      expect(response.body).not_to include('data-controller="onboarding-wizard"')
    end
  end
end
