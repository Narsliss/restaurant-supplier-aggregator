Rails.application.routes.draw do
  devise_for :users, controllers: {
    registrations: 'users/registrations'
  }

  root 'dashboard#index'

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
    resources :memberships, only: %i[update destroy], module: :organizations
    resources :invitations, only: %i[create destroy], module: :organizations do
      post :resend, on: :member
    end
  end

  # Accept invitation (public route)
  get 'invitations/:token/accept', to: 'organizations/invitations#accept', as: :accept_invitation

  # Locations
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

  # Products
  resources :products do
    collection do
      get :search
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
    end
    resources :order_items, only: [:create, :update, :destroy]
  end

  # API namespace
  namespace :api do
    namespace :v1 do
      resources :products, only: %i[index show]
      resources :prices, only: [:index]
      resources :order_lists do
        member do
          get :price_comparison
        end
      end
    end
  end

  # Health check
  get 'up' => 'rails/health#show', as: :rails_health_check

  # Mission Control Jobs Dashboard (super_admin only)
  authenticate :user, ->(u) { u.super_admin? } do
    mount MissionControl::Jobs::Engine, at: '/jobs'
  end
end
