source "https://rubygems.org"

ruby "~> 3.3.0"

# Core Rails
gem "rails", "~> 7.1.0"
gem "pg", "~> 1.5"
gem "puma", "~> 6.4"
gem "bootsnap", require: false

# Asset Pipeline
gem "sprockets-rails"
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "tailwindcss-rails"

# Authentication & Security
gem "devise", "~> 4.9"
gem "attr_encrypted", "~> 4.0"
gem "secure_headers", "~> 6.5"
gem "bcrypt", "~> 3.1"

# Background Jobs
gem "sidekiq", "~> 7.2"
gem "sidekiq-scheduler", "~> 5.0"
gem "redis", "~> 5.0"

# Browser Automation
gem "ferrum", "~> 0.14"

# HTTP & Parsing
gem "faraday", "~> 2.9"
gem "nokogiri", "~> 1.16"

# Pagination
gem "kaminari", "~> 1.2"

# JSON
gem "jbuilder"

# Timezone data for Windows
gem "tzinfo-data", platforms: %i[windows jruby]

group :development, :test do
  gem "debug", platforms: %i[mri windows]
  gem "rspec-rails", "~> 6.1"
  gem "factory_bot_rails", "~> 6.4"
  gem "faker", "~> 3.2"
  gem "dotenv-rails"
end

group :development do
  gem "web-console"
  gem "rack-mini-profiler"
  gem "spring"
  gem "annotate"
  gem "rubocop-rails", require: false
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
  gem "vcr", "~> 6.2"
  gem "webmock", "~> 3.19"
  gem "simplecov", require: false
  gem "shoulda-matchers"
  gem "database_cleaner-active_record"
end
