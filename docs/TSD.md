# Technical Specification Document (TSD)
## Restaurant Supplier Order Aggregator

---

## Document Information

| Item | Details |
|------|---------|
| Project Name | Restaurant Supplier Order Aggregator |
| Version | 1.0 |
| Date | January 26, 2026 |
| Status | Draft |
| Related Documents | Business Requirements Document v1.0 |

---

## 1. System Architecture

### 1.1 Architecture Overview

```
+-----------------------------------------------------------------------------+
|                              CLIENT TIER                                    |
|  +-----------------------------------------------------------------------+  |
|  |                    Web Browser (Hotwire/Turbo)                        |  |
|  +-----------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------+
                                      |
                                      v HTTPS
+-----------------------------------------------------------------------------+
|                           APPLICATION TIER                                  |
|  +------------------------------------------------------------------------+ |
|  |                     Ruby on Rails 7.1+ Application                     | |
|  |  +--------------+  +--------------+  +--------------+  +--------------+| |
|  |  | Controllers  |  |   Models     |  |  Services    |  |   Views      || |
|  |  +--------------+  +--------------+  +--------------+  +--------------+| |
|  +------------------------------------------------------------------------+ |
|                          |                    |                             |
|                          v                    v                             |
|  +------------------------------+    +------------------------------+      |
|  |       Sidekiq Workers        |    |    Headless Chrome (Ferrum)  |      |
|  |  - Price Scraping Jobs       |    |    - Supplier Login          |      |
|  |  - Order Placement Jobs      |    |    - Form Submission         |      |
|  |  - Session Refresh Jobs      |    |    - Data Extraction         |      |
|  +------------------------------+    +------------------------------+      |
+-----------------------------------------------------------------------------+
                    |                              |
                    v                              v
+-------------------------------+    +-----------------------------------------+
|        DATA TIER              |    |         EXTERNAL SERVICES               |
|  +-------------------------+  |    |  +-----------------------------------+  |
|  |     PostgreSQL          |  |    |  |      Supplier Websites            |  |
|  |  - Users                |  |    |  |  - US Foods                       |  |
|  |  - Credentials (enc)    |  |    |  |  - Chef's Warehouse               |  |
|  |  - Products             |  |    |  |  - What Chefs Want                |  |
|  |  - Orders               |  |    |  +-----------------------------------+  |
|  +-------------------------+  |    +-----------------------------------------+
|  +-------------------------+  |
|  |        Redis            |  |
|  |  - Sidekiq Queues       |  |
|  |  - Session Cache        |  |
|  |  - Rate Limiting        |  |
|  +-------------------------+  |
+-------------------------------+
```

### 1.2 Technology Stack

| Layer | Technology | Version | Purpose |
|-------|------------|---------|---------|
| Language | Ruby | 3.3.x | Primary programming language |
| Framework | Ruby on Rails | 7.1.x | Web application framework |
| Database | PostgreSQL | 15.x+ | Primary data store |
| Cache/Queue | Redis | 7.x | Background jobs, caching, rate limiting |
| Background Jobs | Sidekiq | 7.x | Async job processing |
| Browser Automation | Ferrum | 0.14+ | Headless Chrome control |
| Frontend | Hotwire (Turbo + Stimulus) | 7.x / 1.x | SPA-like interactions |
| CSS Framework | Tailwind CSS | 3.x | Styling |
| Testing | RSpec | 3.x | Test framework |
| Authentication | Devise | 4.9.x | User authentication |
| Encryption | attr_encrypted | 4.x | Field-level encryption |
| HTTP Client | Faraday | 2.x | API calls (if needed) |

### 1.3 Deployment Architecture

```
+-----------------------------------------------------------+
|                    Production Environment                  |
|  +-----------------------------------------------------+  |
|  |              Load Balancer (nginx)                  |  |
|  +-----------------------------------------------------+  |
|                          |                                 |
|            +-------------+-------------+                   |
|            v                           v                   |
|  +--------------------+     +--------------------+         |
|  |   Web Server 1     |     |   Web Server 2     |         |
|  |   (Puma + Rails)   |     |   (Puma + Rails)   |         |
|  +--------------------+     +--------------------+         |
|            |                           |                   |
|            +-----------+---------------+                   |
|                        v                                   |
|  +-----------------------------------------------------+  |
|  |              Sidekiq Workers (2-4)                  |  |
|  |         (with Chrome/Chromium installed)            |  |
|  +-----------------------------------------------------+  |
|                        |                                   |
|            +-----------+---------------+                   |
|            v                           v                   |
|  +--------------------+     +--------------------+         |
|  |   PostgreSQL       |     |      Redis         |         |
|  |   (Primary)        |     |   (Sentinel)       |         |
|  +--------------------+     +--------------------+         |
+-----------------------------------------------------------+
```

---

## 2. Database Design

### 2.1 Entity Relationship Diagram

```
+------------------+       +------------------+
|      users       |       |    locations     |
+------------------+       +------------------+
| id (PK)          |--+    | id (PK)          |
| email            |  |    | user_id (FK)     |--+
| encrypted_pwd    |  |    | name             |  |
| role             |  +--->| address          |  |
| created_at       |       | created_at       |  |
| updated_at       |       +------------------+  |
+------------------+                |            |
         |                         |            |
         |       +-----------------+            |
         |       |                              |
         v       v                              |
+------------------------+                      |
|  supplier_credentials  |                      |
+------------------------+    +--------------+  |
| id (PK)                |    |  suppliers   |  |
| user_id (FK)           |    +--------------+  |
| location_id (FK)       |<---| id (PK)      |  |
| supplier_id (FK)       |--->| name         |  |
| encrypted_username     |    | code         |  |
| encrypted_password     |    | base_url     |  |
| encrypted_session_data |    | login_url    |  |
| status                 |    | scraper_class|  |
| last_login_at          |    | active       |  |
| created_at             |    +--------------+  |
+------------------------+           |          |
                                     |          |
+------------------+                 |          |
|    products      |                 |          |
+------------------+                 |          |
| id (PK)          |                 |          |
| name             |                 |          |
| category         |                 |          |
| unit_size        |                 v          |
| upc              |    +--------------------+  |
| created_at       |    | supplier_products  |  |
+------------------+    +--------------------+  |
         |              | id (PK)            |  |
         |              | product_id (FK)    |  |
         +------------->| supplier_id (FK)   |<-+
                        | supplier_sku       |
                        | supplier_name      |
                        | current_price      |
                        | previous_price     |
                        | in_stock           |
                        | price_updated_at   |
                        +--------------------+
                                 |
+------------------+             |
|   order_lists    |             |
+------------------+             |
| id (PK)          |             |
| user_id (FK)     |             |
| name             |             |
| created_at       |             |
+------------------+             |
         |                       |
         v                       |
+--------------------+           |
|  order_list_items  |           |
+--------------------+           |
| id (PK)            |           |
| order_list_id (FK) |           |
| product_id (FK)    |           |
| quantity           |           |
| notes              |           |
+--------------------+           |
                                 |
+------------------+             |
|     orders       |             |
+------------------+             |
| id (PK)          |             |
| user_id (FK)     |             |
| location_id (FK) |             |
| supplier_id (FK) |             |
| order_list_id(FK)|             |
| status           |             |
| confirmation_num |             |
| total_amount     |             |
| submitted_at     |             |
| created_at       |             |
+------------------+             |
         |                       |
         v                       |
+--------------------+           |
|    order_items     |           |
+--------------------+           |
| id (PK)            |           |
| order_id (FK)      |           |
| supplier_product_id|<----------+
| quantity           |
| unit_price         |
| line_total         |
+--------------------+
```

### 2.2 Table Definitions

#### 2.2.1 users

```sql
CREATE TABLE users (
    id              BIGSERIAL PRIMARY KEY,
    email           VARCHAR(255) NOT NULL UNIQUE,
    encrypted_password VARCHAR(255) NOT NULL,
    role            VARCHAR(20) DEFAULT 'user',
    reset_password_token VARCHAR(255),
    reset_password_sent_at TIMESTAMP,
    remember_created_at TIMESTAMP,
    sign_in_count   INTEGER DEFAULT 0,
    current_sign_in_at TIMESTAMP,
    last_sign_in_at TIMESTAMP,
    current_sign_in_ip VARCHAR(45),
    last_sign_in_ip VARCHAR(45),
    failed_attempts INTEGER DEFAULT 0,
    locked_at       TIMESTAMP,
    created_at      TIMESTAMP NOT NULL,
    updated_at      TIMESTAMP NOT NULL
);

CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_reset_token ON users(reset_password_token);
```

#### 2.2.2 locations

```sql
CREATE TABLE locations (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name            VARCHAR(255) NOT NULL,
    address         TEXT,
    city            VARCHAR(100),
    state           VARCHAR(50),
    zip_code        VARCHAR(20),
    phone           VARCHAR(20),
    is_default      BOOLEAN DEFAULT FALSE,
    created_at      TIMESTAMP NOT NULL,
    updated_at      TIMESTAMP NOT NULL
);

CREATE INDEX idx_locations_user ON locations(user_id);
```

#### 2.2.3 suppliers

```sql
CREATE TABLE suppliers (
    id              BIGSERIAL PRIMARY KEY,
    name            VARCHAR(255) NOT NULL,
    code            VARCHAR(50) NOT NULL UNIQUE,
    base_url        VARCHAR(500) NOT NULL,
    login_url       VARCHAR(500) NOT NULL,
    scraper_class   VARCHAR(100) NOT NULL,
    active          BOOLEAN DEFAULT TRUE,
    notes           TEXT,
    created_at      TIMESTAMP NOT NULL,
    updated_at      TIMESTAMP NOT NULL
);

-- Seed data
INSERT INTO suppliers (name, code, base_url, login_url, scraper_class, created_at, updated_at) VALUES
('US Foods', 'usfoods', 'https://www.usfoods.com', 'https://www.usfoods.com/login', 'Scrapers::UsFoods', NOW(), NOW()),
('Chef''s Warehouse', 'chefswarehouse', 'https://www.chefswarehouse.com', 'https://www.chefswarehouse.com/login', 'Scrapers::ChefsWarehouse', NOW(), NOW()),
('What Chefs Want', 'whatchefswant', 'https://www.whatchefswant.com', 'https://www.whatchefswant.com/login', 'Scrapers::WhatChefsWant', NOW(), NOW());
```

#### 2.2.4 supplier_credentials

```sql
CREATE TABLE supplier_credentials (
    id                      BIGSERIAL PRIMARY KEY,
    user_id                 BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    location_id             BIGINT REFERENCES locations(id) ON DELETE CASCADE,
    supplier_id             BIGINT NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE,
    encrypted_username      TEXT NOT NULL,
    encrypted_username_iv   VARCHAR(255) NOT NULL,
    encrypted_password      TEXT NOT NULL,
    encrypted_password_iv   VARCHAR(255) NOT NULL,
    encrypted_session_data  TEXT,
    encrypted_session_data_iv VARCHAR(255),
    status                  VARCHAR(20) DEFAULT 'pending',
    last_login_at           TIMESTAMP,
    last_error              TEXT,
    two_fa_enabled          BOOLEAN DEFAULT FALSE,
    two_fa_type             VARCHAR(50),
    trusted_device_token    TEXT,
    trusted_device_expires_at TIMESTAMP,
    created_at              TIMESTAMP NOT NULL,
    updated_at              TIMESTAMP NOT NULL,
    
    UNIQUE(user_id, location_id, supplier_id)
);

CREATE INDEX idx_supplier_creds_user ON supplier_credentials(user_id);
CREATE INDEX idx_supplier_creds_location ON supplier_credentials(location_id);
CREATE INDEX idx_supplier_creds_status ON supplier_credentials(status);
```

#### 2.2.5 products

```sql
CREATE TABLE products (
    id              BIGSERIAL PRIMARY KEY,
    name            VARCHAR(500) NOT NULL,
    normalized_name VARCHAR(500),
    category        VARCHAR(100),
    subcategory     VARCHAR(100),
    unit_size       VARCHAR(100),
    unit_type       VARCHAR(50),
    upc             VARCHAR(50),
    brand           VARCHAR(255),
    description     TEXT,
    created_at      TIMESTAMP NOT NULL,
    updated_at      TIMESTAMP NOT NULL
);

CREATE INDEX idx_products_name ON products(name);
CREATE INDEX idx_products_normalized ON products(normalized_name);
CREATE INDEX idx_products_upc ON products(upc);
CREATE INDEX idx_products_category ON products(category);
```

#### 2.2.6 supplier_products

```sql
CREATE TABLE supplier_products (
    id                  BIGSERIAL PRIMARY KEY,
    product_id          BIGINT REFERENCES products(id) ON DELETE SET NULL,
    supplier_id         BIGINT NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE,
    supplier_sku        VARCHAR(100) NOT NULL,
    supplier_name       VARCHAR(500) NOT NULL,
    supplier_url        VARCHAR(1000),
    current_price       DECIMAL(10,2),
    previous_price      DECIMAL(10,2),
    pack_size           VARCHAR(100),
    minimum_quantity    INTEGER DEFAULT 1,
    maximum_quantity    INTEGER,
    in_stock            BOOLEAN DEFAULT TRUE,
    price_updated_at    TIMESTAMP,
    last_scraped_at     TIMESTAMP,
    created_at          TIMESTAMP NOT NULL,
    updated_at          TIMESTAMP NOT NULL,
    
    UNIQUE(supplier_id, supplier_sku)
);

CREATE INDEX idx_supplier_products_product ON supplier_products(product_id);
CREATE INDEX idx_supplier_products_supplier ON supplier_products(supplier_id);
CREATE INDEX idx_supplier_products_sku ON supplier_products(supplier_sku);
CREATE INDEX idx_supplier_products_name ON supplier_products(supplier_name);
```

#### 2.2.7 order_lists

```sql
CREATE TABLE order_lists (
    id              BIGSERIAL PRIMARY KEY,
    user_id         BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name            VARCHAR(255) NOT NULL,
    description     TEXT,
    is_favorite     BOOLEAN DEFAULT FALSE,
    last_used_at    TIMESTAMP,
    created_at      TIMESTAMP NOT NULL,
    updated_at      TIMESTAMP NOT NULL
);

CREATE INDEX idx_order_lists_user ON order_lists(user_id);
```

#### 2.2.8 order_list_items

```sql
CREATE TABLE order_list_items (
    id              BIGSERIAL PRIMARY KEY,
    order_list_id   BIGINT NOT NULL REFERENCES order_lists(id) ON DELETE CASCADE,
    product_id      BIGINT NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    quantity        DECIMAL(10,2) NOT NULL DEFAULT 1,
    notes           TEXT,
    position        INTEGER DEFAULT 0,
    created_at      TIMESTAMP NOT NULL,
    updated_at      TIMESTAMP NOT NULL,
    
    UNIQUE(order_list_id, product_id)
);

CREATE INDEX idx_order_list_items_list ON order_list_items(order_list_id);
CREATE INDEX idx_order_list_items_product ON order_list_items(product_id);
```

#### 2.2.9 orders

```sql
CREATE TABLE orders (
    id                  BIGSERIAL PRIMARY KEY,
    user_id             BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    location_id         BIGINT REFERENCES locations(id) ON DELETE SET NULL,
    supplier_id         BIGINT NOT NULL REFERENCES suppliers(id) ON DELETE RESTRICT,
    order_list_id       BIGINT REFERENCES order_lists(id) ON DELETE SET NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'pending',
    confirmation_number VARCHAR(100),
    subtotal            DECIMAL(10,2),
    tax                 DECIMAL(10,2),
    total_amount        DECIMAL(10,2),
    delivery_date       DATE,
    notes               TEXT,
    error_message       TEXT,
    submitted_at        TIMESTAMP,
    confirmed_at        TIMESTAMP,
    created_at          TIMESTAMP NOT NULL,
    updated_at          TIMESTAMP NOT NULL
);

CREATE INDEX idx_orders_user ON orders(user_id);
CREATE INDEX idx_orders_location ON orders(location_id);
CREATE INDEX idx_orders_supplier ON orders(supplier_id);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_orders_submitted ON orders(submitted_at);
```

#### 2.2.10 order_items

```sql
CREATE TABLE order_items (
    id                  BIGSERIAL PRIMARY KEY,
    order_id            BIGINT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    supplier_product_id BIGINT NOT NULL REFERENCES supplier_products(id) ON DELETE RESTRICT,
    quantity            DECIMAL(10,2) NOT NULL,
    unit_price          DECIMAL(10,2) NOT NULL,
    line_total          DECIMAL(10,2) NOT NULL,
    status              VARCHAR(20) DEFAULT 'pending',
    notes               TEXT,
    created_at          TIMESTAMP NOT NULL,
    updated_at          TIMESTAMP NOT NULL
);

CREATE INDEX idx_order_items_order ON order_items(order_id);
CREATE INDEX idx_order_items_product ON order_items(supplier_product_id);
```

#### 2.2.11 supplier_requirements

```sql
CREATE TABLE supplier_requirements (
    id                      BIGSERIAL PRIMARY KEY,
    supplier_id             BIGINT NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE,
    requirement_type        VARCHAR(50) NOT NULL,
    -- Types: 'order_minimum', 'item_minimum', 'delivery_day', 'cutoff_time', 
    --        'service_area', 'max_quantity', 'account_status'
    value                   VARCHAR(255),
    numeric_value           DECIMAL(10,2),
    description             TEXT,
    error_message           TEXT NOT NULL,
    is_blocking             BOOLEAN DEFAULT TRUE,
    active                  BOOLEAN DEFAULT TRUE,
    created_at              TIMESTAMP NOT NULL,
    updated_at              TIMESTAMP NOT NULL
);

CREATE INDEX idx_supplier_requirements_supplier ON supplier_requirements(supplier_id);
CREATE INDEX idx_supplier_requirements_type ON supplier_requirements(requirement_type);

-- Example seed data
INSERT INTO supplier_requirements (supplier_id, requirement_type, numeric_value, description, error_message, created_at, updated_at) VALUES
(1, 'order_minimum', 250.00, 'Minimum order value', 'US Foods requires a minimum order of $250.00. Your current total is ${{current_total}}. Add ${{difference}} more to proceed.', NOW(), NOW()),
(1, 'cutoff_time', NULL, 'Order cutoff for next-day delivery', 'Orders must be placed by 6:00 PM for next-day delivery. Current time: {{current_time}}.', NOW(), NOW()),
(2, 'order_minimum', 200.00, 'Minimum order value', 'Chef''s Warehouse requires a minimum order of $200.00. Your current total is ${{current_total}}.', NOW(), NOW()),
(3, 'order_minimum', 150.00, 'Minimum order value', 'What Chefs Want requires a minimum order of $150.00. Your current total is ${{current_total}}.', NOW(), NOW());
```

#### 2.2.12 supplier_delivery_schedules

```sql
CREATE TABLE supplier_delivery_schedules (
    id                  BIGSERIAL PRIMARY KEY,
    supplier_id         BIGINT NOT NULL REFERENCES suppliers(id) ON DELETE CASCADE,
    location_id         BIGINT REFERENCES locations(id) ON DELETE CASCADE,
    day_of_week         INTEGER NOT NULL, -- 0=Sunday, 6=Saturday
    cutoff_day          INTEGER NOT NULL, -- Day order must be placed
    cutoff_time         TIME NOT NULL,    -- Time order must be placed
    delivery_window     VARCHAR(50),      -- e.g., "6AM-12PM"
    active              BOOLEAN DEFAULT TRUE,
    created_at          TIMESTAMP NOT NULL,
    updated_at          TIMESTAMP NOT NULL
);

CREATE INDEX idx_delivery_schedules_supplier ON supplier_delivery_schedules(supplier_id);
CREATE INDEX idx_delivery_schedules_location ON supplier_delivery_schedules(location_id);
```

#### 2.2.13 order_validations

```sql
CREATE TABLE order_validations (
    id                  BIGSERIAL PRIMARY KEY,
    order_id            BIGINT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    validation_type     VARCHAR(50) NOT NULL,
    passed              BOOLEAN NOT NULL,
    message             TEXT,
    details             JSONB,
    validated_at        TIMESTAMP NOT NULL,
    created_at          TIMESTAMP NOT NULL
);

CREATE INDEX idx_order_validations_order ON order_validations(order_id);
```

#### 2.2.14 supplier_2fa_requests

```sql
CREATE TABLE supplier_2fa_requests (
    id                      BIGSERIAL PRIMARY KEY,
    user_id                 BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    supplier_credential_id  BIGINT NOT NULL REFERENCES supplier_credentials(id) ON DELETE CASCADE,
    session_token           VARCHAR(255) NOT NULL UNIQUE,
    request_type            VARCHAR(50) NOT NULL,  -- 'login', 'checkout', 'price_refresh'
    two_fa_type             VARCHAR(50),           -- 'sms', 'totp', 'email', 'unknown'
    prompt_message          TEXT,                  -- Message shown by supplier
    status                  VARCHAR(20) DEFAULT 'pending',  -- 'pending', 'submitted', 'verified', 'failed', 'expired', 'cancelled'
    code_submitted          VARCHAR(20),           -- The code user entered (for retry logic)
    attempts                INTEGER DEFAULT 0,
    expires_at              TIMESTAMP NOT NULL,
    verified_at             TIMESTAMP,
    created_at              TIMESTAMP NOT NULL,
    updated_at              TIMESTAMP NOT NULL
);

CREATE INDEX idx_2fa_requests_user ON supplier_2fa_requests(user_id);
CREATE INDEX idx_2fa_requests_session ON supplier_2fa_requests(session_token);
CREATE INDEX idx_2fa_requests_status ON supplier_2fa_requests(status);
```

### 2.3 Encryption Strategy

All sensitive credential data is encrypted using AES-256-GCM with the `attr_encrypted` gem:

```ruby
# config/credentials.yml.enc (encrypted)
encryption:
  key: <32-byte hex key>

# Model usage
class SupplierCredential < ApplicationRecord
  attr_encrypted :username, key: Rails.application.credentials.encryption[:key]
  attr_encrypted :password, key: Rails.application.credentials.encryption[:key]
  attr_encrypted :session_data, key: Rails.application.credentials.encryption[:key]
end
```

---

## 3. Application Structure

### 3.1 Directory Structure

```
restaurant-supplier-aggregator/
├── app/
│   ├── controllers/
│   │   ├── application_controller.rb
│   │   ├── dashboard_controller.rb
│   │   ├── locations_controller.rb
│   │   ├── supplier_credentials_controller.rb
│   │   ├── products_controller.rb
│   │   ├── order_lists_controller.rb
│   │   ├── price_comparisons_controller.rb
│   │   └── orders_controller.rb
│   │
│   ├── models/
│   │   ├── application_record.rb
│   │   ├── user.rb
│   │   ├── location.rb
│   │   ├── supplier.rb
│   │   ├── supplier_credential.rb
│   │   ├── supplier_requirement.rb
│   │   ├── supplier_delivery_schedule.rb
│   │   ├── supplier_2fa_request.rb
│   │   ├── product.rb
│   │   ├── supplier_product.rb
│   │   ├── order_list.rb
│   │   ├── order_list_item.rb
│   │   ├── order.rb
│   │   ├── order_item.rb
│   │   └── order_validation.rb
│   │
│   ├── services/
│   │   ├── scrapers/
│   │   │   ├── base_scraper.rb
│   │   │   ├── us_foods_scraper.rb
│   │   │   ├── chefs_warehouse_scraper.rb
│   │   │   └── what_chefs_want_scraper.rb
│   │   ├── authentication/
│   │   │   ├── supplier_authenticator.rb
│   │   │   ├── session_manager.rb
│   │   │   └── two_factor_handler.rb
│   │   ├── orders/
│   │   │   ├── price_comparison_service.rb
│   │   │   ├── order_builder_service.rb
│   │   │   ├── order_placement_service.rb
│   │   │   └── order_validation_service.rb
│   │   └── products/
│   │       ├── product_matcher.rb
│   │       └── product_normalizer.rb
│   │
│   ├── jobs/
│   │   ├── application_job.rb
│   │   ├── scrape_prices_job.rb
│   │   ├── scrape_supplier_job.rb
│   │   ├── refresh_session_job.rb
│   │   ├── place_order_job.rb
│   │   ├── validate_credentials_job.rb
│   │   └── two_factor_notification_job.rb
│   │
│   ├── channels/
│   │   ├── application_cable/
│   │   │   ├── channel.rb
│   │   │   └── connection.rb
│   │   └── two_factor_channel.rb
│   │
│   ├── views/
│   │   ├── layouts/
│   │   ├── shared/
│   │   │   └── _two_factor_modal.html.erb
│   │   ├── dashboard/
│   │   ├── locations/
│   │   ├── supplier_credentials/
│   │   ├── order_lists/
│   │   ├── price_comparisons/
│   │   └── orders/
│   │
│   └── javascript/
│       ├── application.js
│       ├── channels/
│       │   ├── consumer.js
│       │   └── two_factor_channel.js
│       └── controllers/
│           ├── price_comparison_controller.js
│           ├── order_list_controller.js
│           ├── order_placement_controller.js
│           └── two_factor_controller.js
│
├── config/
│   ├── routes.rb
│   ├── cable.yml
│   ├── sidekiq.yml
│   ├── initializers/
│   │   ├── devise.rb
│   │   ├── sidekiq.rb
│   │   └── ferrum.rb
│   └── credentials.yml.enc
│
├── db/
│   ├── migrate/
│   └── seeds.rb
│
├── lib/
│   └── tasks/
│       └── scraping.rake
│
└── spec/
    ├── models/
    ├── services/
    ├── jobs/
    ├── channels/
    ├── requests/
    └── factories/
```

### 3.2 Routes

```ruby
# config/routes.rb
Rails.application.routes.draw do
  devise_for :users
  
  root 'dashboard#index'
  
  resources :locations
  
  resources :supplier_credentials do
    member do
      post :validate
      post :refresh_session
    end
  end
  
  resources :products do
    collection do
      get :search
    end
  end
  
  resources :order_lists do
    member do
      post :duplicate
      get :price_comparison
    end
    resources :order_list_items, only: [:create, :update, :destroy]
  end
  
  resources :price_comparisons, only: [:show] do
    member do
      post :refresh_prices
    end
  end
  
  resources :orders do
    member do
      post :submit
      post :cancel
    end
    collection do
      get :history
    end
  end
  
  namespace :api do
    namespace :v1 do
      resources :products, only: [:index, :show]
      resources :prices, only: [:index]
    end
  end
  
  require 'sidekiq/web'
  authenticate :user, ->(u) { u.admin? } do
    mount Sidekiq::Web => '/sidekiq'
  end
end
```

---

## 4. Core Service Classes

### 4.1 Base Scraper

```ruby
# app/services/scrapers/base_scraper.rb
module Scrapers
  class BaseScraper
    class AuthenticationError < StandardError; end
    class ScrapingError < StandardError; end
    class SessionExpiredError < StandardError; end
    class OrderMinimumError < StandardError
      attr_reader :minimum, :current_total
      def initialize(message, minimum:, current_total:)
        @minimum = minimum
        @current_total = current_total
        super(message)
      end
    end
    class ItemUnavailableError < StandardError
      attr_reader :items
      def initialize(message, items:)
        @items = items
        super(message)
      end
    end
    class CaptchaDetectedError < StandardError; end
    class AccountHoldError < StandardError; end
    class DeliveryUnavailableError < StandardError; end
    class PriceChangedError < StandardError
      attr_reader :changes
      def initialize(message, changes:)
        @changes = changes
        super(message)
      end
    end
    class RateLimitedError < StandardError; end
    class MaintenanceError < StandardError; end
    
    attr_reader :credential, :browser, :logger
    
    def initialize(credential)
      @credential = credential
      @logger = Rails.logger
    end
    
    def with_browser(&block)
      @browser = Ferrum::Browser.new(
        headless: true,
        timeout: 30,
        window_size: [1920, 1080],
        browser_options: {
          'no-sandbox': true,
          'disable-gpu': true
        }
      )
      yield(browser)
    ensure
      browser&.quit
    end
    
    def login_with_2fa_support
      with_browser do
        # Try to use trusted device token first
        if restore_trusted_device
          navigate_to(supplier_base_url)
          return true if logged_in?
        end
        
        # Attempt normal login
        perform_login_steps
        
        # Check if 2FA is required
        two_fa_handler = Authentication::TwoFactorHandler.new(
          credential, browser, operation_type: 'login'
        )
        
        if two_fa_handler.two_fa_required?
          two_fa_handler.initiate_2fa_flow
        end
        
        finalize_login
      end
    end
    
    # Override in subclasses
    def login
      raise NotImplementedError
    end
    
    def scrape_prices(product_skus)
      raise NotImplementedError
    end
    
    def add_to_cart(items)
      raise NotImplementedError
    end
    
    def checkout
      raise NotImplementedError
    end
    
    protected
    
    def navigate_to(url)
      browser.goto(url)
      wait_for_page_load
    end
    
    def fill_field(selector, value)
      browser.at_css(selector)&.focus&.type(value)
    end
    
    def click(selector)
      browser.at_css(selector)&.click
    end
    
    def wait_for_page_load
      sleep 0.5
    end
    
    def wait_for_selector(selector, timeout: 10)
      start_time = Time.current
      loop do
        return true if browser.at_css(selector)
        raise ScrapingError, "Timeout waiting for #{selector}" if Time.current - start_time > timeout
        sleep 0.1
      end
    end
    
    def extract_text(selector)
      browser.at_css(selector)&.text&.strip
    end
    
    def extract_price(text)
      return nil unless text
      text.gsub(/[^0-9.]/, '').to_f
    end
    
    def save_session
      cookies = browser.cookies.all.map { |name, cookie| cookie.to_h }
      credential.update!(
        session_data: cookies.to_json,
        last_login_at: Time.current,
        status: 'active'
      )
    end
    
    def restore_session
      return false unless credential.session_data.present?
      
      cookies = JSON.parse(credential.session_data)
      cookies.each do |cookie|
        browser.cookies.set(
          name: cookie['name'],
          value: cookie['value'],
          domain: cookie['domain'],
          path: cookie['path'] || '/',
          expires: cookie['expires'],
          secure: cookie['secure'],
          httponly: cookie['httponly']
        )
      end
      true
    rescue JSON::ParserError
      false
    end
    
    def detect_error_conditions
      detect_captcha
      detect_maintenance
      detect_account_issues
    end
    
    def detect_captcha
      captcha_indicators = [
        '#captcha',
        '.captcha-container',
        'iframe[src*="recaptcha"]',
        '.g-recaptcha',
        '#challenge-form'
      ]
      
      captcha_indicators.each do |selector|
        if browser.at_css(selector)
          raise CaptchaDetectedError, "CAPTCHA detected. Manual intervention required."
        end
      end
    end
    
    def detect_maintenance
      maintenance_indicators = [
        'maintenance',
        'temporarily unavailable',
        'scheduled downtime',
        'under construction'
      ]
      
      page_text = browser.body&.text&.downcase || ''
      
      maintenance_indicators.each do |indicator|
        if page_text.include?(indicator)
          raise MaintenanceError, "Supplier site is under maintenance. Please try again later."
        end
      end
    end
    
    def detect_account_issues
      # Override in subclasses for supplier-specific detection
    end
    
    def restore_trusted_device
      return false unless credential.trusted_device_token.present?
      return false if credential.trusted_device_expires_at&.past?
      false # Override in subclasses
    end
    
    def perform_login_steps
      raise NotImplementedError
    end
    
    def finalize_login
      if logged_in?
        save_session
        credential.update!(status: 'active', last_login_at: Time.current)
        true
      else
        error_msg = extract_text('.error-message') || 'Login failed'
        credential.update!(status: 'failed', last_error: error_msg)
        raise AuthenticationError, error_msg
      end
    end
  end
end
```

### 4.2 US Foods Scraper

```ruby
# app/services/scrapers/us_foods_scraper.rb
module Scrapers
  class UsFoodsScraper < BaseScraper
    BASE_URL = 'https://www.usfoods.com'.freeze
    LOGIN_URL = "#{BASE_URL}/sign-in".freeze
    ORDER_MINIMUM = 250.00
    
    def login
      with_browser do
        navigate_to(BASE_URL)
        if restore_session
          browser.refresh
          return true if logged_in?
        end
        
        navigate_to(LOGIN_URL)
        wait_for_selector('#username')
        
        fill_field('#username', credential.username)
        fill_field('#password', credential.password)
        click('button[type="submit"]')
        
        wait_for_page_load
        sleep 2
        
        if logged_in?
          save_session
          credential.update!(status: 'active', last_login_at: Time.current)
          true
        else
          error_msg = extract_text('.error-message') || 'Login failed'
          credential.update!(status: 'failed', last_error: error_msg)
          raise AuthenticationError, error_msg
        end
      end
    end
    
    def scrape_prices(product_skus)
      results = []
      
      with_browser do
        login unless logged_in?
        
        product_skus.each do |sku|
          begin
            result = scrape_product(sku)
            results << result if result
          rescue ScrapingError => e
            logger.warn "Failed to scrape SKU #{sku}: #{e.message}"
          end
          
          sleep rand(1.0..2.0)
        end
      end
      
      results
    end
    
    def add_to_cart(items)
      with_browser do
        login unless logged_in?
        
        items.each do |item|
          navigate_to("#{BASE_URL}/product/#{item[:sku]}")
          wait_for_selector('.add-to-cart')
          
          qty_field = browser.at_css('input[name="quantity"]')
          qty_field&.focus
          qty_field&.type(item[:quantity].to_s, :clear)
          
          click('.add-to-cart')
          wait_for_selector('.cart-confirmation', timeout: 5)
          
          sleep rand(0.5..1.0)
        end
        
        true
      end
    end
    
    def checkout
      with_browser do
        navigate_to("#{BASE_URL}/cart")
        wait_for_selector('.cart-contents')
        
        validate_cart_before_checkout
        
        minimum_check = check_order_minimum_at_checkout
        unless minimum_check[:met]
          raise OrderMinimumError.new(
            "Order minimum not met",
            minimum: minimum_check[:minimum],
            current_total: minimum_check[:current]
          )
        end
        
        unavailable = detect_unavailable_items_in_cart
        if unavailable.any?
          raise ItemUnavailableError.new(
            "#{unavailable.count} item(s) are unavailable",
            items: unavailable
          )
        end
        
        price_changes = detect_price_changes_in_cart
        if price_changes.any?
          raise PriceChangedError.new(
            "Prices have changed for #{price_changes.count} item(s)",
            changes: price_changes
          )
        end
        
        click('.checkout-button')
        wait_for_selector('.order-review')
        
        unless delivery_date_available?
          raise DeliveryUnavailableError, "No delivery dates available for your location"
        end
        
        click('.place-order-button')
        wait_for_confirmation_or_error
        
        {
          confirmation_number: extract_text('.confirmation-number'),
          total: extract_price(extract_text('.order-total')),
          delivery_date: extract_text('.delivery-date')
        }
      end
    end
    
    private
    
    def logged_in?
      browser.at_css('.user-account-menu').present? ||
        browser.at_css('.logged-in-indicator').present?
    end
    
    def scrape_product(sku)
      navigate_to("#{BASE_URL}/product/#{sku}")
      
      return nil unless browser.at_css('.product-detail')
      
      {
        supplier_sku: sku,
        supplier_name: extract_text('.product-title'),
        current_price: extract_price(extract_text('.product-price')),
        pack_size: extract_text('.pack-size'),
        in_stock: browser.at_css('.out-of-stock').nil?,
        scraped_at: Time.current
      }
    end
    
    def check_order_minimum_at_checkout
      subtotal_text = extract_text('.cart-subtotal')
      current_total = extract_price(subtotal_text)
      
      minimum_text = extract_text('.order-minimum-message')
      minimum = if minimum_text
        extract_price(minimum_text)
      else
        ORDER_MINIMUM
      end
      
      {
        met: current_total >= minimum,
        minimum: minimum,
        current: current_total
      }
    end
    
    def detect_unavailable_items_in_cart
      unavailable = []
      
      browser.css('.cart-item').each do |item|
        if item.at_css('.out-of-stock') || item.at_css('.unavailable')
          unavailable << {
            sku: item.at_css('[data-sku]')&.attribute('data-sku'),
            name: item.at_css('.item-name')&.text&.strip,
            message: item.at_css('.availability-message')&.text&.strip
          }
        end
      end
      
      unavailable
    end
    
    def detect_price_changes_in_cart
      changes = []
      
      browser.css('.cart-item').each do |item|
        price_warning = item.at_css('.price-changed-warning')
        next unless price_warning
        
        changes << {
          sku: item.at_css('[data-sku]')&.attribute('data-sku'),
          name: item.at_css('.item-name')&.text&.strip,
          old_price: extract_price(item.at_css('.original-price')&.text),
          new_price: extract_price(item.at_css('.current-price')&.text)
        }
      end
      
      changes
    end
    
    def validate_cart_before_checkout
      detect_error_conditions
      
      if browser.at_css('.empty-cart')
        raise ScrapingError, "Cart is empty"
      end
    end
    
    def delivery_date_available?
      browser.at_css('.delivery-date-selector option:not([disabled])').present?
    end
    
    def wait_for_confirmation_or_error
      start_time = Time.current
      timeout = 30
      
      loop do
        return true if browser.at_css('.order-confirmation')
        
        error_msg = browser.at_css('.checkout-error')&.text&.strip
        if error_msg
          handle_checkout_error(error_msg)
        end
        
        raise ScrapingError, "Checkout timeout" if Time.current - start_time > timeout
        sleep 0.5
      end
    end
    
    def handle_checkout_error(error_msg)
      case error_msg.downcase
      when /minimum.*order/
        raise OrderMinimumError.new(error_msg, minimum: ORDER_MINIMUM, current_total: 0)
      when /credit.*hold/, /account.*hold/
        raise AccountHoldError, error_msg
      when /out of stock/, /unavailable/
        raise ItemUnavailableError.new(error_msg, items: [])
      when /delivery.*unavailable/
        raise DeliveryUnavailableError, error_msg
      else
        raise ScrapingError, "Checkout failed: #{error_msg}"
      end
    end
    
    def detect_account_issues
      hold_banner = browser.at_css('.account-hold-banner')
      if hold_banner
        raise AccountHoldError, hold_banner.text.strip
      end
      
      credit_warning = browser.at_css('.credit-limit-warning')
      if credit_warning
        raise AccountHoldError, "Credit limit reached: #{credit_warning.text.strip}"
      end
    end
  end
end
```

### 4.3 Two-Factor Authentication Handler

```ruby
# app/services/authentication/two_factor_handler.rb
module Authentication
  class TwoFactorHandler
    class TwoFactorRequired < StandardError
      attr_reader :request_id, :two_fa_type, :prompt_message, :session_token
      
      def initialize(request_id:, two_fa_type:, prompt_message:, session_token:)
        @request_id = request_id
        @two_fa_type = two_fa_type
        @prompt_message = prompt_message
        @session_token = session_token
        super("Two-factor authentication required")
      end
    end
    
    attr_reader :credential, :browser, :operation_type
    
    TIMEOUT_MINUTES = 5
    MAX_ATTEMPTS = 3
    
    def initialize(credential, browser, operation_type: 'login')
      @credential = credential
      @browser = browser
      @operation_type = operation_type
    end
    
    def two_fa_required?
      detect_2fa_prompt.present?
    end
    
    def initiate_2fa_flow
      prompt_info = detect_2fa_prompt
      return nil unless prompt_info
      
      request = Supplier2faRequest.create!(
        user: credential.user,
        supplier_credential: credential,
        session_token: SecureRandom.urlsafe_base64(32),
        request_type: operation_type,
        two_fa_type: prompt_info[:type],
        prompt_message: prompt_info[:message],
        status: 'pending',
        expires_at: TIMEOUT_MINUTES.minutes.from_now
      )
      
      notify_user_2fa_required(request)
      
      raise TwoFactorRequired.new(
        request_id: request.id,
        two_fa_type: prompt_info[:type],
        prompt_message: prompt_info[:message],
        session_token: request.session_token
      )
    end
    
    def submit_code(request, code)
      return { success: false, error: 'Request expired' } if request.expired?
      return { success: false, error: 'Max attempts exceeded' } if request.attempts >= MAX_ATTEMPTS
      
      request.increment!(:attempts)
      request.update!(code_submitted: code, status: 'submitted')
      
      result = enter_2fa_code(code)
      
      if result[:success]
        request.update!(status: 'verified', verified_at: Time.current)
        save_trusted_device_if_available
        { success: true }
      else
        if request.attempts >= MAX_ATTEMPTS
          request.update!(status: 'failed')
          { success: false, error: 'Max attempts exceeded', can_retry: false }
        else
          { success: false, error: result[:error], can_retry: true, attempts_remaining: MAX_ATTEMPTS - request.attempts }
        end
      end
    end
    
    def cancel(request)
      request.update!(status: 'cancelled')
    end
    
    private
    
    def detect_2fa_prompt
      indicators = {
        sms: [
          'input[name*="sms"]',
          'input[name*="phone_code"]',
          '.sms-verification',
          '[data-testid="sms-code-input"]'
        ],
        totp: [
          'input[name*="totp"]',
          'input[name*="authenticator"]',
          '.authenticator-code',
          '[data-testid="totp-input"]'
        ],
        email: [
          'input[name*="email_code"]',
          '.email-verification',
          '[data-testid="email-code-input"]'
        ],
        generic: [
          'input[name*="verification_code"]',
          'input[name*="2fa"]',
          'input[name*="mfa"]',
          '.two-factor-input',
          '.verification-code-input',
          '#verificationCode'
        ]
      }
      
      indicators.each do |type, selectors|
        selectors.each do |selector|
          element = browser.at_css(selector)
          if element
            message = extract_2fa_message
            return { type: type, selector: selector, message: message }
          end
        end
      end
      
      page_text = browser.body&.text&.downcase || ''
      if page_text.match?(/enter.*code|verification.*code|two.?factor|2fa|authenticator/)
        input = browser.at_css('input[type="text"], input[type="tel"], input[type="number"]')
        if input
          return { type: :unknown, selector: nil, message: extract_2fa_message }
        end
      end
      
      nil
    end
    
    def extract_2fa_message
      message_selectors = [
        '.verification-message',
        '.two-factor-instructions',
        '.mfa-prompt',
        'label[for*="code"]',
        '.form-description',
        'p.instructions'
      ]
      
      message_selectors.each do |selector|
        element = browser.at_css(selector)
        return element.text.strip if element&.text.present?
      end
      
      "Please enter your verification code"
    end
    
    def enter_2fa_code(code)
      input = browser.at_css('input[name*="code"], input[name*="2fa"], input[name*="verification"], .verification-code-input input')
      
      unless input
        return { success: false, error: 'Could not find code input field' }
      end
      
      input.focus
      input.type(code, :clear)
      
      submit = browser.at_css('button[type="submit"], input[type="submit"], .verify-button, .submit-code')
      submit&.click
      
      sleep 2
      
      if two_fa_required?
        error = browser.at_css('.error-message, .alert-danger, .invalid-code')&.text&.strip
        { success: false, error: error || 'Invalid code' }
      else
        { success: true }
      end
    end
    
    def save_trusted_device_if_available
      remember_checkbox = browser.at_css('input[name*="remember"], input[name*="trust"], #rememberDevice')
      
      if remember_checkbox && !remember_checkbox.checked?
        remember_checkbox.click
      end
      
      trusted_cookie = browser.cookies.all.find { |name, _| name.match?(/trusted|remember|device/i) }
      
      if trusted_cookie
        credential.update!(
          trusted_device_token: trusted_cookie[1].value,
          trusted_device_expires_at: 30.days.from_now
        )
      end
    end
    
    def notify_user_2fa_required(request)
      TwoFactorChannel.broadcast_to(
        credential.user,
        {
          type: 'two_fa_required',
          request_id: request.id,
          session_token: request.session_token,
          supplier_name: credential.supplier.name,
          two_fa_type: request.two_fa_type,
          prompt_message: request.prompt_message,
          expires_at: request.expires_at.iso8601
        }
      )
      
      TwoFactorNotificationJob.perform_later(request.id)
    end
  end
end
```

### 4.4 Order Validation Service

```ruby
# app/services/orders/order_validation_service.rb
module Orders
  class OrderValidationService
    class ValidationError < StandardError
      attr_reader :errors, :warnings
      
      def initialize(errors: [], warnings: [])
        @errors = errors
        @warnings = warnings
        super(errors.map { |e| e[:message] }.join('; '))
      end
    end
    
    attr_reader :order, :errors, :warnings
    
    def initialize(order)
      @order = order
      @errors = []
      @warnings = []
    end
    
    def validate!
      run_validations
      
      if errors.any?
        raise ValidationError.new(errors: errors, warnings: warnings)
      end
      
      { valid: true, warnings: warnings }
    end
    
    def valid?
      run_validations
      errors.empty?
    end
    
    private
    
    def run_validations
      @errors = []
      @warnings = []
      
      validate_order_minimum
      validate_item_minimums
      validate_item_maximums
      validate_item_availability
      validate_delivery_schedule
      validate_cutoff_time
      validate_account_status
      validate_service_area
      validate_price_changes
      
      log_validations
    end
    
    def validate_order_minimum
      requirement = supplier_requirement('order_minimum')
      return unless requirement
      
      minimum = requirement.numeric_value
      current_total = order.calculated_subtotal
      
      if current_total < minimum
        difference = minimum - current_total
        add_error(
          type: 'order_minimum',
          message: interpolate_message(requirement.error_message, {
            current_total: format_currency(current_total),
            minimum: format_currency(minimum),
            difference: format_currency(difference)
          }),
          details: {
            minimum: minimum,
            current_total: current_total,
            difference: difference
          }
        )
      end
    end
    
    def validate_item_minimums
      order.order_items.each do |item|
        sp = item.supplier_product
        next unless sp.minimum_quantity && sp.minimum_quantity > 0
        
        if item.quantity < sp.minimum_quantity
          add_error(
            type: 'item_minimum',
            message: "#{sp.supplier_name} requires a minimum quantity of #{sp.minimum_quantity}. You ordered #{item.quantity}.",
            details: {
              product_id: sp.id,
              product_name: sp.supplier_name,
              minimum: sp.minimum_quantity,
              ordered: item.quantity
            }
          )
        end
      end
    end
    
    def validate_item_maximums
      order.order_items.each do |item|
        sp = item.supplier_product
        next unless sp.maximum_quantity && sp.maximum_quantity > 0
        
        if item.quantity > sp.maximum_quantity
          add_error(
            type: 'item_maximum',
            message: "#{sp.supplier_name} has a maximum order quantity of #{sp.maximum_quantity}. You ordered #{item.quantity}.",
            details: {
              product_id: sp.id,
              product_name: sp.supplier_name,
              maximum: sp.maximum_quantity,
              ordered: item.quantity
            }
          )
        end
      end
    end
    
    def validate_item_availability
      unavailable = order.order_items.joins(:supplier_product)
        .where(supplier_products: { in_stock: false })
      
      unavailable.each do |item|
        add_error(
          type: 'item_unavailable',
          message: "#{item.supplier_product.supplier_name} is currently out of stock.",
          details: {
            product_id: item.supplier_product.id,
            product_name: item.supplier_product.supplier_name
          }
        )
      end
    end
    
    def validate_delivery_schedule
      schedule = SupplierDeliverySchedule.find_by(
        supplier: order.supplier,
        location: order.location,
        active: true
      )
      
      return unless schedule
      
      next_delivery = calculate_next_delivery(schedule)
      
      if next_delivery.nil?
        add_warning(
          type: 'no_delivery',
          message: "No delivery available for your location from #{order.supplier.name} on the requested date.",
          details: { supplier: order.supplier.name }
        )
      end
    end
    
    def validate_cutoff_time
      requirement = supplier_requirement('cutoff_time')
      return unless requirement
      
      schedule = SupplierDeliverySchedule.find_by(
        supplier: order.supplier,
        location: order.location,
        active: true
      )
      
      return unless schedule
      
      cutoff_datetime = calculate_cutoff_datetime(schedule)
      
      if Time.current > cutoff_datetime
        add_error(
          type: 'cutoff_passed',
          message: "Order cutoff time has passed. Orders for #{order.supplier.name} must be placed by #{schedule.cutoff_time.strftime('%I:%M %p')}.",
          details: {
            cutoff_time: cutoff_datetime,
            current_time: Time.current
          }
        )
      elsif Time.current > cutoff_datetime - 1.hour
        add_warning(
          type: 'cutoff_approaching',
          message: "Order cutoff is approaching! You have #{time_until(cutoff_datetime)} to place this order.",
          details: {
            cutoff_time: cutoff_datetime,
            time_remaining: cutoff_datetime - Time.current
          }
        )
      end
    end
    
    def validate_account_status
      credential = order.user.supplier_credentials.find_by(
        supplier: order.supplier
      )
      
      unless credential&.status == 'active'
        add_error(
          type: 'account_inactive',
          message: "Your #{order.supplier.name} account is not active. Please verify your credentials.",
          details: { status: credential&.status }
        )
      end
    end
    
    def validate_service_area
      requirement = supplier_requirement('service_area')
      return unless requirement && order.location
      
      unless supplier_serves_location?(order.supplier, order.location)
        add_error(
          type: 'service_area',
          message: "#{order.supplier.name} does not deliver to #{order.location.city}, #{order.location.state}.",
          details: {
            location: order.location.full_address,
            supplier: order.supplier.name
          }
        )
      end
    end
    
    def validate_price_changes
      price_changes = []
      
      order.order_items.each do |item|
        sp = item.supplier_product
        
        if item.unit_price != sp.current_price
          change_pct = ((sp.current_price - item.unit_price) / item.unit_price * 100).round(2)
          
          price_changes << {
            product_name: sp.supplier_name,
            old_price: item.unit_price,
            new_price: sp.current_price,
            change_percent: change_pct
          }
        end
      end
      
      if price_changes.any?
        total_old = price_changes.sum { |pc| pc[:old_price] }
        total_new = price_changes.sum { |pc| pc[:new_price] }
        
        add_warning(
          type: 'price_changed',
          message: "#{price_changes.count} item(s) have changed price since you created this order.",
          details: {
            changes: price_changes,
            total_difference: total_new - total_old
          }
        )
      end
    end
    
    def supplier_requirement(type)
      SupplierRequirement.find_by(
        supplier: order.supplier,
        requirement_type: type,
        active: true
      )
    end
    
    def add_error(type:, message:, details: {})
      @errors << { type: type, message: message, details: details, blocking: true }
    end
    
    def add_warning(type:, message:, details: {})
      @warnings << { type: type, message: message, details: details, blocking: false }
    end
    
    def interpolate_message(template, values)
      result = template.dup
      values.each do |key, value|
        result.gsub!("{{#{key}}}", value.to_s)
      end
      result
    end
    
    def format_currency(amount)
      "$#{'%.2f' % amount}"
    end
    
    def log_validations
      (@errors + @warnings).each do |validation|
        OrderValidation.create!(
          order: order,
          validation_type: validation[:type],
          passed: !validation[:blocking],
          message: validation[:message],
          details: validation[:details],
          validated_at: Time.current
        )
      end
    end
  end
end
```

### 4.5 Price Comparison Service

```ruby
# app/services/orders/price_comparison_service.rb
module Orders
  class PriceComparisonService
    attr_reader :order_list, :user
    
    def initialize(order_list)
      @order_list = order_list
      @user = order_list.user
    end
    
    def compare
      items = order_list.order_list_items.includes(product: :supplier_products)
      
      comparison = items.map do |item|
        product = item.product
        supplier_prices = build_supplier_prices(product, item.quantity)
        
        {
          product: product,
          quantity: item.quantity,
          suppliers: supplier_prices,
          best_price: find_best_price(supplier_prices),
          price_spread: calculate_spread(supplier_prices)
        }
      end
      
      {
        items: comparison,
        totals_by_supplier: calculate_totals(comparison),
        recommendations: generate_recommendations(comparison)
      }
    end
    
    private
    
    def build_supplier_prices(product, quantity)
      active_suppliers.map do |supplier|
        supplier_product = product.supplier_products.find_by(supplier: supplier)
        
        if supplier_product&.current_price
          {
            supplier: supplier,
            supplier_product: supplier_product,
            unit_price: supplier_product.current_price,
            line_total: supplier_product.current_price * quantity,
            in_stock: supplier_product.in_stock,
            last_updated: supplier_product.price_updated_at
          }
        else
          {
            supplier: supplier,
            supplier_product: nil,
            unit_price: nil,
            line_total: nil,
            in_stock: false,
            last_updated: nil,
            unavailable: true
          }
        end
      end
    end
    
    def active_suppliers
      @active_suppliers ||= user.supplier_credentials
        .where(status: 'active')
        .includes(:supplier)
        .map(&:supplier)
    end
    
    def find_best_price(supplier_prices)
      available = supplier_prices.select { |sp| sp[:in_stock] && sp[:unit_price] }
      return nil if available.empty?
      available.min_by { |sp| sp[:unit_price] }
    end
    
    def calculate_spread(supplier_prices)
      prices = supplier_prices.map { |sp| sp[:unit_price] }.compact
      return 0 if prices.size < 2
      prices.max - prices.min
    end
    
    def calculate_totals(comparison)
      totals = Hash.new { |h, k| h[k] = { total: 0, available_items: 0, missing_items: 0 } }
      
      comparison.each do |item|
        item[:suppliers].each do |sp|
          if sp[:line_total]
            totals[sp[:supplier]][:total] += sp[:line_total]
            totals[sp[:supplier]][:available_items] += 1
          else
            totals[sp[:supplier]][:missing_items] += 1
          end
        end
      end
      
      totals
    end
    
    def generate_recommendations(comparison)
      totals = calculate_totals(comparison)
      
      best = totals.min_by { |_, v| v[:total] if v[:missing_items] == 0 }
      
      {
        best_single_supplier: best&.first,
        split_order_savings: calculate_split_savings(comparison)
      }
    end
    
    def calculate_split_savings(comparison)
      single_supplier_best = calculate_totals(comparison).values.map { |v| v[:total] }.min
      
      split_total = comparison.sum do |item|
        item[:best_price]&.dig(:line_total) || 0
      end
      
      single_supplier_best - split_total
    end
  end
end
```

### 4.6 Order Placement Service

```ruby
# app/services/orders/order_placement_service.rb
module Orders
  class OrderPlacementService
    attr_reader :order, :scraper, :validation_result
    
    def initialize(order)
      @order = order
    end
    
    def place_order(accept_price_changes: false, skip_warnings: false)
      validate_order!(skip_warnings: skip_warnings)
      
      credential = get_active_credential
      
      @scraper = order.supplier.scraper_class.constantize.new(credential)
      
      order.update!(status: 'processing')
      
      begin
        cart_items = build_cart_items
        scraper.add_to_cart(cart_items)
        
        result = scraper.checkout
        
        order.update!(
          status: 'submitted',
          confirmation_number: result[:confirmation_number],
          total_amount: result[:total],
          submitted_at: Time.current,
          delivery_date: result[:delivery_date]
        )
        
        { success: true, order: order }
        
      rescue Scrapers::BaseScraper::OrderMinimumError => e
        handle_order_minimum_error(e)
        
      rescue Scrapers::BaseScraper::ItemUnavailableError => e
        handle_item_unavailable_error(e)
        
      rescue Scrapers::BaseScraper::PriceChangedError => e
        handle_price_changed_error(e, accept_price_changes)
        
      rescue Scrapers::BaseScraper::AccountHoldError => e
        handle_account_hold_error(e)
        
      rescue Scrapers::BaseScraper::CaptchaDetectedError => e
        handle_captcha_error(e)
        
      rescue Scrapers::BaseScraper::DeliveryUnavailableError => e
        handle_delivery_error(e)
        
      rescue => e
        handle_generic_error(e)
      end
    end
    
    private
    
    def validate_order!(skip_warnings: false)
      validator = OrderValidationService.new(order)
      @validation_result = validator.validate!
      
      unless skip_warnings
        if validation_result[:warnings].any?
          order.update!(
            status: 'pending_review',
            notes: "Warnings: #{validation_result[:warnings].map { |w| w[:message] }.join('; ')}"
          )
        end
      end
    end
    
    def get_active_credential
      credential = order.user.supplier_credentials.find_by(
        supplier: order.supplier,
        status: 'active'
      )
      
      unless credential
        order.update!(status: 'failed', error_message: "No active credentials for #{order.supplier.name}")
        raise OrderValidationService::ValidationError.new(
          errors: [{ type: 'no_credentials', message: "No active credentials for #{order.supplier.name}" }]
        )
      end
      
      credential
    end
    
    def build_cart_items
      order.order_items.includes(:supplier_product).map do |item|
        {
          sku: item.supplier_product.supplier_sku,
          quantity: item.quantity,
          expected_price: item.unit_price
        }
      end
    end
    
    def handle_order_minimum_error(error)
      difference = error.minimum - error.current_total
      
      order.update!(
        status: 'failed',
        error_message: "Order minimum not met. Minimum: $#{'%.2f' % error.minimum}, " \
                       "Current: $#{'%.2f' % error.current_total}. " \
                       "Add $#{'%.2f' % difference} more to proceed."
      )
      
      {
        success: false,
        error_type: 'order_minimum',
        error: error.message,
        details: {
          minimum: error.minimum,
          current_total: error.current_total,
          difference: difference
        }
      }
    end
    
    def handle_item_unavailable_error(error)
      order.update!(
        status: 'failed',
        error_message: "#{error.items.count} item(s) are unavailable: " \
                       "#{error.items.map { |i| i[:name] }.join(', ')}"
      )
      
      {
        success: false,
        error_type: 'items_unavailable',
        error: error.message,
        details: { unavailable_items: error.items }
      }
    end
    
    def handle_price_changed_error(error, accept_changes)
      if accept_changes
        update_order_with_new_prices(error.changes)
        return place_order(accept_price_changes: true)
      end
      
      order.update!(
        status: 'pending_review',
        error_message: "Prices changed for #{error.changes.count} item(s). Review required."
      )
      
      {
        success: false,
        error_type: 'price_changed',
        error: error.message,
        details: { price_changes: error.changes },
        requires_review: true
      }
    end
    
    def handle_account_hold_error(error)
      credential = order.user.supplier_credentials.find_by(supplier: order.supplier)
      credential&.update!(status: 'hold', last_error: error.message)
      
      order.update!(
        status: 'failed',
        error_message: "Account issue: #{error.message}"
      )
      
      {
        success: false,
        error_type: 'account_hold',
        error: error.message,
        requires_manual_resolution: true
      }
    end
    
    def handle_captcha_error(error)
      order.update!(
        status: 'pending_manual',
        error_message: "CAPTCHA detected. Manual order placement required."
      )
      
      {
        success: false,
        error_type: 'captcha',
        error: error.message,
        requires_manual_intervention: true,
        supplier_url: order.supplier.base_url
      }
    end
    
    def handle_delivery_error(error)
      order.update!(
        status: 'failed',
        error_message: error.message
      )
      
      {
        success: false,
        error_type: 'delivery_unavailable',
        error: error.message
      }
    end
    
    def handle_generic_error(error)
      Rails.logger.error "Order placement failed: #{error.class} - #{error.message}"
      Rails.logger.error error.backtrace.join("\n")
      
      order.update!(
        status: 'failed',
        error_message: "Order failed: #{error.message}"
      )
      
      {
        success: false,
        error_type: 'unknown',
        error: error.message
      }
    end
    
    def update_order_with_new_prices(changes)
      changes.each do |change|
        item = order.order_items.joins(:supplier_product)
          .find_by(supplier_products: { supplier_sku: change[:sku] })
        
        next unless item
        
        item.update!(
          unit_price: change[:new_price],
          line_total: change[:new_price] * item.quantity
        )
      end
      
      order.recalculate_totals!
    end
  end
end
```

---

## 5. Background Jobs

### 5.1 Sidekiq Configuration

```yaml
# config/sidekiq.yml
:concurrency: 5
:queues:
  - [critical, 3]
  - [default, 2]
  - [scraping, 1]
  - [low, 1]

:schedule:
  refresh_prices:
    cron: '0 4 * * *'  # Daily at 4 AM
    class: ScrapePricesJob
    queue: scraping
    
  refresh_sessions:
    cron: '0 */6 * * *'  # Every 6 hours
    class: RefreshSessionJob
    queue: default
```

### 5.2 Scrape Prices Job

```ruby
# app/jobs/scrape_prices_job.rb
class ScrapePricesJob < ApplicationJob
  queue_as :scraping
  
  def perform(supplier_id = nil)
    suppliers = supplier_id ? [Supplier.find(supplier_id)] : Supplier.active
    
    suppliers.each do |supplier|
      ScrapeSupplierJob.perform_later(supplier.id)
    end
  end
end
```

### 5.3 Scrape Supplier Job

```ruby
# app/jobs/scrape_supplier_job.rb
class ScrapeSupplierJob < ApplicationJob
  queue_as :scraping
  retry_on StandardError, wait: 5.minutes, attempts: 3
  
  def perform(supplier_id, credential_id = nil)
    supplier = Supplier.find(supplier_id)
    
    credentials = if credential_id
      [SupplierCredential.find(credential_id)]
    else
      SupplierCredential.where(supplier: supplier, status: 'active')
    end
    
    credentials.each do |credential|
      scraper = supplier.scraper_class.constantize.new(credential)
      
      skus = credential.user.order_list_items
        .joins(product: :supplier_products)
        .where(supplier_products: { supplier_id: supplier.id })
        .pluck('supplier_products.supplier_sku')
        .uniq
      
      next if skus.empty?
      
      results = scraper.scrape_prices(skus)
      
      results.each do |result|
        supplier_product = SupplierProduct.find_by(
          supplier: supplier,
          supplier_sku: result[:supplier_sku]
        )
        
        next unless supplier_product
        
        supplier_product.update!(
          previous_price: supplier_product.current_price,
          current_price: result[:current_price],
          in_stock: result[:in_stock],
          price_updated_at: Time.current,
          last_scraped_at: Time.current
        )
      end
    end
  end
end
```

### 5.4 Place Order Job

```ruby
# app/jobs/place_order_job.rb
class PlaceOrderJob < ApplicationJob
  queue_as :critical
  
  def perform(order_id)
    order = Order.find(order_id)
    
    service = Orders::OrderPlacementService.new(order)
    service.place_order
    
    OrderMailer.order_confirmed(order).deliver_later
  rescue => e
    Rails.logger.error "Order placement failed: #{e.message}"
    OrderMailer.order_failed(order, e.message).deliver_later
    raise
  end
end
```

---

## 6. ActionCable Channels

### 6.1 Two Factor Channel

```ruby
# app/channels/two_factor_channel.rb
class TwoFactorChannel < ApplicationCable::Channel
  def subscribed
    stream_for current_user
  end
  
  def submit_code(data)
    request = Supplier2faRequest.find_by(
      session_token: data['session_token'],
      user: current_user,
      status: 'pending'
    )
    
    unless request
      transmit({ type: 'error', message: 'Invalid or expired request' })
      return
    end
    
    result = TwoFactorCodeSubmissionJob.perform_now(request.id, data['code'])
    
    transmit({
      type: 'code_result',
      success: result[:success],
      error: result[:error],
      can_retry: result[:can_retry],
      attempts_remaining: result[:attempts_remaining]
    })
  end
  
  def cancel(data)
    request = Supplier2faRequest.find_by(
      session_token: data['session_token'],
      user: current_user
    )
    
    request&.update!(status: 'cancelled')
    transmit({ type: 'cancelled' })
  end
end
```

---

## 7. Frontend Components

### 7.1 Two Factor Controller (Stimulus)

```javascript
// app/javascript/controllers/two_factor_controller.js
import { Controller } from "@hotwired/stimulus"
import consumer from "../channels/consumer"

export default class extends Controller {
  static targets = ["modal", "codeInput", "message", "timer", "error", "submitBtn"]
  static values = {
    sessionToken: String,
    expiresAt: String
  }
  
  connect() {
    this.subscription = consumer.subscriptions.create("TwoFactorChannel", {
      received: this.handleMessage.bind(this)
    })
  }
  
  disconnect() {
    this.subscription?.unsubscribe()
    this.stopTimer()
  }
  
  handleMessage(data) {
    switch(data.type) {
      case 'two_fa_required':
        this.showModal(data)
        break
      case 'code_result':
        this.handleCodeResult(data)
        break
      case 'cancelled':
        this.hideModal()
        break
    }
  }
  
  showModal(data) {
    this.sessionTokenValue = data.session_token
    this.expiresAtValue = data.expires_at
    
    this.messageTarget.textContent = data.prompt_message
    this.modalTarget.classList.remove('hidden')
    this.codeInputTarget.focus()
    this.errorTarget.classList.add('hidden')
    
    this.startTimer()
    this.showNotification(data.supplier_name)
  }
  
  hideModal() {
    this.modalTarget.classList.add('hidden')
    this.codeInputTarget.value = ''
    this.stopTimer()
  }
  
  submitCode() {
    const code = this.codeInputTarget.value.trim()
    if (!code) return
    
    this.submitBtnTarget.disabled = true
    this.submitBtnTarget.textContent = 'Verifying...'
    
    this.subscription.perform('submit_code', {
      session_token: this.sessionTokenValue,
      code: code
    })
  }
  
  handleCodeResult(data) {
    this.submitBtnTarget.disabled = false
    this.submitBtnTarget.textContent = 'Verify'
    
    if (data.success) {
      this.hideModal()
      window.location.reload()
    } else {
      this.errorTarget.textContent = data.error
      if (data.attempts_remaining) {
        this.errorTarget.textContent += ` (${data.attempts_remaining} attempts remaining)`
      }
      this.errorTarget.classList.remove('hidden')
      this.codeInputTarget.value = ''
      this.codeInputTarget.focus()
      
      if (!data.can_retry) {
        this.submitBtnTarget.disabled = true
        this.submitBtnTarget.textContent = 'Max attempts reached'
      }
    }
  }
  
  cancel() {
    this.subscription.perform('cancel', {
      session_token: this.sessionTokenValue
    })
    this.hideModal()
  }
  
  startTimer() {
    const expiresAt = new Date(this.expiresAtValue)
    
    this.timerInterval = setInterval(() => {
      const now = new Date()
      const remaining = Math.max(0, Math.floor((expiresAt - now) / 1000))
      
      if (remaining <= 0) {
        this.timerTarget.textContent = 'Expired'
        this.stopTimer()
        this.submitBtnTarget.disabled = true
        return
      }
      
      const minutes = Math.floor(remaining / 60)
      const seconds = remaining % 60
      this.timerTarget.textContent = `${minutes}:${seconds.toString().padStart(2, '0')}`
    }, 1000)
  }
  
  stopTimer() {
    if (this.timerInterval) {
      clearInterval(this.timerInterval)
    }
  }
  
  showNotification(supplierName) {
    if (Notification.permission === 'granted') {
      new Notification('Verification Required', {
        body: `${supplierName} requires a verification code`,
        icon: '/icon.png'
      })
    }
  }
  
  handleKeydown(event) {
    if (event.key === 'Enter') {
      this.submitCode()
    }
  }
}
```

### 7.2 Two Factor Modal (ERB)

```erb
<!-- app/views/shared/_two_factor_modal.html.erb -->
<div data-controller="two-factor"
     data-two-factor-session-token-value=""
     data-two-factor-expires-at-value="">
  
  <div data-two-factor-target="modal" 
       class="hidden fixed inset-0 bg-gray-600 bg-opacity-50 flex items-center justify-center z-50">
    <div class="bg-white rounded-lg shadow-xl p-6 w-full max-w-md">
      <h2 class="text-xl font-bold mb-4">Verification Required</h2>
      
      <p data-two-factor-target="message" class="text-gray-600 mb-4">
        Please enter your verification code
      </p>
      
      <div class="mb-4">
        <label class="block text-sm font-medium text-gray-700 mb-1">
          Verification Code
        </label>
        <input type="text" 
               data-two-factor-target="codeInput"
               data-action="keydown->two-factor#handleKeydown"
               class="w-full px-3 py-2 border border-gray-300 rounded-md text-center text-2xl tracking-widest"
               placeholder="000000"
               maxlength="10"
               autocomplete="one-time-code"
               inputmode="numeric">
      </div>
      
      <div data-two-factor-target="error" 
           class="hidden mb-4 p-3 bg-red-100 text-red-700 rounded-md text-sm">
      </div>
      
      <div class="flex items-center justify-between mb-4">
        <span class="text-sm text-gray-500">
          Time remaining: <span data-two-factor-target="timer">5:00</span>
        </span>
      </div>
      
      <div class="flex space-x-3">
        <button data-two-factor-target="submitBtn"
                data-action="click->two-factor#submitCode"
                class="flex-1 bg-blue-600 text-white py-2 px-4 rounded-md hover:bg-blue-700">
          Verify
        </button>
        <button data-action="click->two-factor#cancel"
                class="flex-1 bg-gray-200 text-gray-700 py-2 px-4 rounded-md hover:bg-gray-300">
          Cancel
        </button>
      </div>
    </div>
  </div>
</div>
```

---

## 8. Security Specifications

### 8.1 Credential Encryption

| Aspect | Specification |
|--------|---------------|
| Algorithm | AES-256-GCM |
| Key Storage | Rails encrypted credentials |
| IV Generation | Unique per-record, per-field |
| Key Rotation | Manual process, re-encrypt all records |

### 8.2 Authentication

| Feature | Implementation |
|---------|----------------|
| Password Hashing | bcrypt (Devise default) |
| Session Duration | 30 minutes idle timeout |
| Remember Me | 2 weeks |
| Rate Limiting | 5 failed attempts = 1 hour lockout |

### 8.3 Security Headers

```ruby
# config/initializers/secure_headers.rb
SecureHeaders::Configuration.default do |config|
  config.x_frame_options = "DENY"
  config.x_content_type_options = "nosniff"
  config.x_xss_protection = "1; mode=block"
  config.content_security_policy = {
    default_src: %w('self'),
    script_src: %w('self'),
    style_src: %w('self' 'unsafe-inline')
  }
end
```

---

## 9. API Specifications (Internal)

### 9.1 Price Comparison Endpoint

```
GET /api/v1/order_lists/:id/price_comparison

Response:
{
  "order_list_id": 123,
  "items": [
    {
      "product_id": 456,
      "product_name": "Chicken Breast 10lb",
      "quantity": 5,
      "suppliers": [
        {
          "supplier_id": 1,
          "supplier_name": "US Foods",
          "unit_price": 25.99,
          "line_total": 129.95,
          "in_stock": true,
          "last_updated": "2026-01-26T10:00:00Z"
        }
      ],
      "best_price": {
        "supplier_id": 2,
        "unit_price": 24.50
      }
    }
  ],
  "totals": {
    "us_foods": { "total": 523.45, "available_items": 10, "missing_items": 0 },
    "chefs_warehouse": { "total": 498.20, "available_items": 9, "missing_items": 1 }
  }
}
```

---

## 10. Testing Strategy

### 10.1 Test Coverage Targets

| Layer | Target Coverage |
|-------|-----------------|
| Models | 95% |
| Services | 90% |
| Controllers | 85% |
| Jobs | 85% |
| Channels | 80% |
| Overall | 85% |

### 10.2 Testing Tools

| Tool | Purpose |
|------|---------|
| RSpec | Test framework |
| FactoryBot | Test data generation |
| VCR | HTTP interaction recording |
| WebMock | HTTP request stubbing |
| Capybara | Feature/integration tests |
| SimpleCov | Coverage reporting |

---

## 11. Deployment & Operations

### 11.1 Environment Variables

```bash
# Required
DATABASE_URL=postgres://user:pass@host:5432/dbname
REDIS_URL=redis://localhost:6379/0
RAILS_MASTER_KEY=<master-key-for-credentials>
SECRET_KEY_BASE=<random-64-byte-hex>

# Optional
RAILS_LOG_LEVEL=info
SIDEKIQ_CONCURRENCY=5
CHROME_PATH=/usr/bin/chromium
```

### 11.2 System Dependencies

- Ruby 3.3+
- PostgreSQL 15+
- Redis 7+
- Chromium/Chrome (for Ferrum)
- Node.js 18+ (for asset compilation)

### 11.3 Monitoring

| Aspect | Tool |
|--------|------|
| Application Performance | New Relic / Skylight |
| Error Tracking | Sentry / Honeybadger |
| Job Monitoring | Sidekiq Web UI |
| Uptime | Pingdom / UptimeRobot |

---

## 12. Gem Dependencies

```ruby
# Gemfile (relevant additions)
gem 'devise'
gem 'attr_encrypted'
gem 'ferrum'
gem 'sidekiq'
gem 'sidekiq-scheduler'
gem 'redis'
gem 'tailwindcss-rails'
gem 'turbo-rails'
gem 'stimulus-rails'
gem 'faraday'
gem 'nokogiri'
gem 'secure_headers'

group :development, :test do
  gem 'rspec-rails'
  gem 'factory_bot_rails'
  gem 'faker'
  gem 'vcr'
  gem 'webmock'
end

group :test do
  gem 'capybara'
  gem 'simplecov'
end
```

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-26 | | Initial draft |
