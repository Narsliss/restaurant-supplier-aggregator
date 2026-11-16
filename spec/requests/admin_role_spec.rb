require 'rails_helper'

# Nov 16 2026: a second person needs the admin dashboard without becoming a
# second super admin (alerts, jobs, billing changes stay with Carmin).
# The "admin" role: admin dashboard + support actions + read-only impersonation.
# See docs/admin-role.md.
RSpec.describe 'Admin role', type: :request do
  let!(:super_admin) do
    User.where(role: 'super_admin').destroy_all
    create(:user, :super_admin)
  end
  let(:admin) { create(:user, :admin) }
  let(:chef) { create(:user, :fully_onboarded) }
  let(:target_org) do
    org = create(:organization)
    create(:membership, user: create(:user), organization: org, role: 'owner')
    org
  end

  describe 'the role itself' do
    it 'allows more than one admin and leaves the single super admin alone' do
      create(:user, :admin)
      create(:user, :admin)
      expect(User.where(role: 'admin').count).to eq(2)
      # Every alert mailer looks up User.super_admin; admins must not change it.
      expect(User.super_admin).to eq(super_admin)
    end

    it 'gives dashboard access but no super admin powers' do
      expect(admin.admin_access?).to be(true)
      expect(admin.super_admin?).to be(false)
      expect(admin.can_access_any_organization?).to be(false)
    end
  end

  describe 'pages an admin can open' do
    before { sign_in admin }

    it 'opens every admin dashboard page' do
      [admin_root_path, admin_organizations_path, admin_organization_path(target_org),
       admin_revenue_path, admin_operations_path, admin_usage_path,
       admin_supplier_portal_users_path, admin_user_path(chef)].each do |path|
        get path
        expect(response).to have_http_status(:ok), "expected 200 for #{path}, got #{response.status}"
      end
    end

    it 'sends the app home page and restaurant pages to the admin dashboard' do
      get root_path
      expect(response).to redirect_to(admin_root_path)
      get order_lists_path
      expect(response).to redirect_to(admin_root_path)
    end

    it 'can still open their own account settings' do
      get edit_user_registration_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'super admin only' do
    before { sign_in admin }

    it 'keeps the jobs dashboard closed' do
      get '/jobs'
      expect(response).not_to have_http_status(:ok)
    end

    it 'keeps the Stripe cleanup page closed' do
      get admin_billing_cutover_path
      expect(response).to redirect_to(admin_root_path)
    end

    it 'refuses suspending an organization' do
      expect { post suspend_admin_organization_path(target_org) }
        .not_to change { target_org.reload.suspended_at }
      expect(response).to redirect_to(admin_root_path)
    end

    it 'refuses granting free access' do
      expect { post grant_complimentary_admin_organization_path(target_org), params: { reason: 'x' } }
        .not_to change { target_org.reload.complimentary? }
    end

    it 'refuses changing a supplier stock mode' do
      supplier = create(:supplier, morning_stock_mode: 'shadow')
      patch stock_mode_admin_operations_path, params: { supplier_id: supplier.id, mode: 'live' }
      expect(supplier.reload.morning_stock_mode).to eq('shadow')
    end

    it 'refuses creating salespeople and inviting supplier users' do
      get new_admin_user_path
      expect(response).to redirect_to(admin_root_path)
      get new_admin_supplier_portal_user_path
      expect(response).to redirect_to(admin_root_path)
    end

    it 'hides the super admin buttons on the organization page' do
      get admin_organization_path(target_org)
      expect(response.body).not_to include('Suspend')
      expect(response.body).not_to include('Grant Free Access')
    end

    it 'hides Jobs, CRM and Products in the admin nav' do
      get admin_root_path
      doc = Nokogiri::HTML(response.body)
      links = doc.css('nav a').map { |a| a.text.strip }
      expect(links).to include('Organizations', 'Revenue')
      expect(links).not_to include('Jobs', 'CRM', 'Products', 'Exit to App')
    end
  end

  describe 'the super admin still sees everything' do
    before { sign_in super_admin }

    it 'shows Suspend and the Jobs link' do
      get admin_organization_path(target_org)
      expect(response.body).to include('Suspend')
      links = Nokogiri::HTML(response.body).css('nav a').map { |a| a.text.strip }
      expect(links).to include('Jobs', 'CRM', 'Products')
    end
  end

  describe 'support actions an admin can take' do
    before { sign_in admin }

    it 'unlocks a locked account' do
      chef.lock_access!(send_instructions: false)
      post unlock_admin_user_path(chef)
      expect(chef.reload.locked_at).to be_nil
    end

    it 'sends a password reset' do
      expect { post reset_password_admin_user_path(chef) }
        .to change { chef.reload.reset_password_token }
    end
  end

  describe 'viewing as a user' do
    before { sign_in admin }

    it 'views as a regular user, read-only, and returns to the admin dashboard' do
      post impersonate_admin_user_path(chef)
      expect(response).to redirect_to(root_path)

      # Writes are blocked while viewing as someone else
      expect { post order_lists_path, params: { order_list: { name: 'Should not save' } } }
        .not_to change(OrderList, :count)
      expect(flash[:alert]).to include('Read-only mode')

      post admin_stop_impersonating_path
      expect(response).to redirect_to(admin_user_path(chef))
      get admin_root_path
      expect(response).to have_http_status(:ok)
    end

    it 'cannot view as the super admin or another admin' do
      [super_admin, create(:user, :admin)].each do |target|
        post impersonate_admin_user_path(target)
        expect(response).to redirect_to(admin_user_path(target))
        get admin_root_path
        expect(response).to have_http_status(:ok) # still signed in as the admin
      end
    end
  end
end
