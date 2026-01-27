# Restaurant Supplier Order Aggregator

A Ruby on Rails application that streamlines restaurant procurement by consolidating ordering across multiple food suppliers into a single platform.

## Features

- **Multi-Supplier Support**: Connect to US Foods, Chef's Warehouse, and What Chefs Want
- **Automated Authentication**: Secure credential storage with automatic login/session management
- **Two-Factor Authentication**: Real-time 2FA handling with browser notifications
- **Price Comparison**: Compare prices across suppliers for your order lists
- **Order Automation**: Automated cart building and checkout on supplier websites
- **Order Validation**: Pre-submission validation for minimums, cutoff times, availability
- **Multi-Location**: Support for multiple restaurant locations

## Requirements

- Ruby 3.3+
- Rails 7.1+
- PostgreSQL 15+
- Redis 7+
- Chrome/Chromium (for browser automation)
- Node.js 18+ (for asset compilation)

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/yourusername/restaurant-supplier-aggregator.git
cd restaurant-supplier-aggregator
```

### 2. Install dependencies

```bash
bundle install
```

### 3. Setup the database

```bash
rails db:create
rails db:migrate
rails db:seed
```

### 4. Configure environment variables

Create a `.env` file in the root directory:

```env
DATABASE_URL=postgres://localhost/restaurant_supplier_aggregator_development
REDIS_URL=redis://localhost:6379/0
RAILS_MASTER_KEY=your-master-key
```

### 5. Start the services

```bash
# Terminal 1: Start Redis
redis-server

# Terminal 2: Start Sidekiq
bundle exec sidekiq

# Terminal 3: Start Rails
bin/rails server
```

### 6. Access the application

Open http://localhost:3000

**Demo credentials:**
- Email: `demo@example.com`
- Password: `password123`

**Admin credentials:**
- Email: `admin@example.com`
- Password: `admin123`

## Architecture

```
app/
├── controllers/         # Request handling
├── models/             # Data models with validations
├── services/           # Business logic
│   ├── scrapers/       # Supplier-specific web scrapers
│   ├── authentication/ # 2FA and session management
│   └── orders/         # Order validation, placement, comparison
├── jobs/               # Background jobs (Sidekiq)
├── channels/           # ActionCable for real-time updates
└── views/              # ERB templates with Tailwind CSS
```

## Key Components

### Scrapers

Each supplier has a dedicated scraper class that handles:
- Login/authentication
- Price scraping
- Cart management
- Checkout automation

### Services

- `OrderValidationService`: Validates orders against supplier requirements
- `PriceComparisonService`: Compares prices across suppliers
- `OrderPlacementService`: Handles order submission with error recovery
- `TwoFactorHandler`: Manages 2FA during automation

### Background Jobs

- `ScrapePricesJob`: Daily price updates
- `RefreshSessionJob`: Keeps supplier sessions active
- `PlaceOrderJob`: Asynchronous order placement
- `ValidateCredentialsJob`: Verifies supplier credentials

## Configuration

### Sidekiq Schedule

Scheduled jobs are configured in `config/sidekiq.yml`:
- Price refresh: Daily at 4 AM
- Session refresh: Every 6 hours
- 2FA cleanup: Every 5 minutes

### Security

- Credentials encrypted with AES-256
- Session tokens for 2FA requests
- Rate limiting on login attempts

## Development

### Running Tests

```bash
bundle exec rspec
```

### Code Style

```bash
bundle exec rubocop
```

### Database Console

```bash
rails dbconsole
```

## API Endpoints

### Internal API (v1)

- `GET /api/v1/products` - List products
- `GET /api/v1/order_lists/:id/price_comparison` - Compare prices

## Troubleshooting

### Scraper Issues

1. Check Chrome/Chromium is installed
2. Verify credentials are valid
3. Check supplier website hasn't changed

### 2FA Not Working

1. Ensure ActionCable is connected
2. Check Redis is running
3. Verify browser allows notifications

### Session Expiring

Sessions refresh every 6 hours. If issues persist:
1. Manually refresh via "Refresh Session" button
2. Check Sidekiq logs for errors

## License

MIT License - See LICENSE file for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request
