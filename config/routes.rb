Rails.application.routes.draw do
  devise_for :users, controllers: {
    registrations: 'users/registrations',
    passwords: 'users/passwords'
  }

  # Supplier Portal Auth (separate Devise scope)
  devise_for :supplier_users, path: "supplier", controllers: {
    sessions: "supplier_portal/sessions",
    passwords: "supplier_portal/passwords"
  }

  # Accept supplier portal invitation (public routes)
  get "supplier/invitations/:token/accept", to: "supplier_portal/invitations#show", as: :accept_supplier_portal_invitation
  post "supplier/invitations/:token/accept", to: "supplier_portal/invitations#accept"

  # Supplier Portal (authenticated supplier users)
  authenticate :supplier_user do
    namespace :supplier_portal, path: "supplier" do
      root to: "dashboard#index"

      resources :products, only: [:index, :show] do
        collection do
          get :health
        end
      end

      resources :orders, only: [:index, :show] do
        collection do
          get :export
        end
      end

      resources :abandoned_carts, only: [:index, :show]

      resources :customers, only: [:index, :show]

      resource :analytics, only: [:show], controller: "analytics" do
        collection do
          get :revenue
          get :products
        end
      end
    end
  end

  root 'dashboard#index'
  post 'onboarding/dismiss', to: 'dashboard#dismiss_onboarding', as: :dismiss_onboarding

  # Stripe Webhooks
  namespace :webhooks do
    post 'stripe', to: 'stripe#create'
  end

  # Subscription & Billing
  resource :subscription, only: %i[show new create] do
    get :success
    get :cancel
    post :billing_portal
    post :cancel_subscription
    post :reactivate
  end

  # Organizations & Team Management
  resource :organization, only: %i[show new create edit update] do
    post :switch, on: :member
    post :update_case_minimum, on: :collection
    resources :memberships, only: %i[update destroy], module: :organizations do
      patch :update_locations, on: :member
    end
    resources :invitations, only: %i[create edit update destroy], module: :organizations do
      post :resend, on: :member
    end
  end

  # Reports (owners + managers)
  resources :reports, only: [:index]

  # Accept invitation (public route)
  get 'invitations/:token/accept', to: 'organizations/invitations#accept', as: :accept_invitation

  # Locations
  post 'locations/switch', to: 'locations#switch', as: :switch_location
  resources :locations

  # Supplier Credentials
  resources :supplier_credentials do
    member do
      post :validate
      post :refresh_session
      post :import_products
      post :import_lists
      post :submit_2fa_code
      get :status
    end
  end

  # Supplier Lists (scraped order guides) — URL: /order-lists
  resources :supplier_lists, only: %i[index show], path: "order-lists" do
    member do
      post :sync
    end
    collection do
      post :sync_all
    end
  end

  # Aggregated Lists (cross-supplier list groupings — managed from Supplier Lists page)
  resources :aggregated_lists, except: [:index] do
    member do
      post :run_matching
      post :search_catalog
      get :order_builder
    end
    resources :product_matches, only: %i[index] do
      member do
        post :confirm
        post :reject
      end
      collection do
        post :confirm_all
      end
    end
  end

  # Product Match Item create + update (manual supplier item assignment)
  resources :product_match_items, only: [:create, :update]

  # Favorite Products (toggle from order builder)
  resources :favorite_products, only: [] do
    collection do
      post :toggle
    end
  end

  # Products
  resources :products do
    collection do
      get :search
      post :refresh_catalog
    end
  end

  # Order Lists
  resources :order_lists do
    member do
      post :duplicate
      get :price_comparison
    end
    resources :order_list_items, only: %i[create update destroy]
  end

  # Price Comparisons
  resources :price_comparisons, only: [:show] do
    member do
      post :refresh_prices
    end
  end

  # Orders — URL: /order-history
  resources :orders, path: "order-history" do
    member do
      post :submit
      post :cancel
      post :reorder
      get :placement_status
      post :retry_order
    end
    collection do
      get :split_preview
      post :split_create
      post :create_from_aggregated_list
      get :review
      post :submit_batch
      get :verification_status
      post :accept_price_changes
      post :retry_verification
      post :skip_verification
      get :batch_progress
      get :batch_placement_status
    end
    resources :order_items, only: [:create, :update, :destroy]
  end

  # AI Event Menu Planner
  resources :event_plans, path: "menu-planner" do
    resources :messages, only: [:create], controller: "event_plan_messages"
    member do
      post :build_order
    end
  end

  # Static pages
  get 'terms', to: 'pages#terms', as: :terms

  # Health check
  get 'up' => 'rails/health#show', as: :rails_health_check

  # Stop impersonating — must be OUTSIDE the super_admin authenticate block
  # because the signed-in user during impersonation is NOT the super admin.
  namespace :admin do
    post 'stop_impersonating', to: 'users#stop_impersonating'
  end

  # Super Admin Dashboard & Tools
  authenticate :user, ->(u) { u.super_admin? } do
    namespace :admin do
      root to: 'dashboard#index'

      resources :users, only: [:index, :show] do
        member do
          post :unlock
          post :reset_password
          post :impersonate
        end
      end

      resources :organizations, only: [:index, :show] do
        member do
          post :suspend
          post :reactivate
          post :reinvite
          post :grant_complimentary
          post :revoke_complimentary
          post :extend_trial
          post :cancel_subscription
        end
      end

      resource :revenue, only: [:show]
      resource :operations, only: [:show]
      resource :usage, only: [:show]

      # Supplier Portal User Management
      resources :supplier_portal_users, only: [:index, :new, :create]
    end

    mount MissionControl::Jobs::Engine, at: '/jobs'
  end
end
