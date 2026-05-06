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

    it 'passes the image-paths map (digest-aware) to the JS controller' do
      get root_path
      expect(response.body).to include('data-onboarding-wizard-image-paths-value=')
      # At minimum, the keys we author in shared.js + owner.js should be present
      expect(response.body).to include('product-matching')
      expect(response.body).to include('order-review')
      expect(response.body).to include('supplier-credentials')
    end

    it 'passes computed completed steps so the JS can skip already-done steps' do
      # :fully_onboarded creates org, location, and a teammate — these should auto-mark "organization", "restaurant", and "team" complete
      get root_path
      expect(response.body).to match(/data-onboarding-wizard-completed-steps-value=".*organization.*restaurant.*team/)
    end

    it 'annotates real nav items with data-onboarding-target hooks' do
      get root_path
      expect(response.body).to include('data-onboarding-target="nav-orderhistory"')
      expect(response.body).to include('data-onboarding-target="nav-orderlists"')
      expect(response.body).to include('data-onboarding-target="nav-neworder"')
      expect(response.body).to include('data-onboarding-target="nav-reports"')
      expect(response.body).to include('data-onboarding-target="menu-supplier-creds"')
      expect(response.body).to include('data-onboarding-target="menu-product-matching"')
      expect(response.body).to include('data-onboarding-target="menu-settings"')
      expect(response.body).to include('data-onboarding-target="menu-team"')
      expect(response.body).to include('data-onboarding-target="menu-restaurants"')
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

  describe 'while the legacy hard-gate onboarding is still in progress' do
    let(:user) { create(:user) } # no org yet — onboarding_incomplete? = true
    before { sign_in user }

    it 'suppresses the wizard partial so legacy fullscreen onboarding can run' do
      get root_path
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
