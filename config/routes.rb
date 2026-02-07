Rails.application.routes.draw do
  devise_for :users, controllers: {
    registrations: "users/registrations"
  }

  root "dashboard#index"

  # Stripe Webhooks
  namespace :webhooks do
    post "stripe", to: "stripe#create"
  end

  # Subscription & Billing
  resource :subscription, only: [:show, :new, :create] do
    get :success
    get :cancel
    post :billing_portal
    post :cancel_subscription
    post :reactivate
  end

  # Organizations & Team Management
  resource :organization, only: [:show, :new, :create, :edit, :update] do
    post :switch, on: :member
    resources :memberships, only: [:update, :destroy], module: :organizations
    resources :invitations, only: [:create, :destroy], module: :organizations do
      post :resend, on: :member
    end
  end

  # Accept invitation (public route)
  get "invitations/:token/accept", to: "organizations/invitations#accept", as: :accept_invitation

  # Locations
  resources :locations

  # Supplier Credentials
  resources :supplier_credentials do
    member do
      post :validate
      post :refresh_session
      post :import_products
      post :submit_2fa_code
      get :status
    end
  end

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
    resources :order_list_items, only: [:create, :update, :destroy]
  end

  # Price Comparisons
  resources :price_comparisons, only: [:show] do
    member do
      post :refresh_prices
    end
  end

  # Orders
  resources :orders do
    member do
      post :submit
      post :cancel
    end
    collection do
      get :history
      get :split_preview
      post :split_create
    end
  end

  # API namespace
  namespace :api do
    namespace :v1 do
      resources :products, only: [:index, :show]
      resources :prices, only: [:index]
      resources :order_lists do
        member do
          get :price_comparison
        end
      end
    end
  end

  # Health check
  get "up" => "rails/health#show", as: :rails_health_check

  # Sidekiq Web UI (super_admin only)
  require "sidekiq/web"
  authenticate :user, ->(u) { u.super_admin? } do
    mount Sidekiq::Web => "/sidekiq"
  end
end
