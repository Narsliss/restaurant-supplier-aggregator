# Business Requirements Document (BRD)
## Restaurant Supplier Order Aggregator

---

## Document Information

| Item | Details |
|------|---------|
| Project Name | Restaurant Supplier Order Aggregator |
| Version | 1.0 |
| Date | January 26, 2026 |
| Status | Draft |

---

## 1. Executive Summary

### 1.1 Purpose

This application enables restaurant operators to streamline their procurement process by consolidating ordering across multiple food suppliers (US Foods, Chef's Warehouse, What Chefs Want) into a single platform. The system provides automated authentication to supplier portals, centralized order list management, real-time price comparison, and automated order placement.

### 1.2 Business Problem

Restaurant operators currently face:

- **Time inefficiency**: Logging into multiple supplier websites separately
- **Price opacity**: Difficulty comparing prices for the same/similar products across suppliers
- **Manual tracking**: No centralized view of frequently ordered items
- **Order fragmentation**: Managing orders across disparate systems
- **Missed savings**: Inability to quickly identify the best-priced supplier for each item

### 1.3 Proposed Solution

A centralized web application that:

- Maintains secure, encrypted credentials for each supplier account
- Automates login and session management for supplier portals
- Handles two-factor authentication requirements from supplier sites
- Scrapes and aggregates current pricing from all connected suppliers
- Allows users to create and manage reusable order lists
- Displays side-by-side price comparisons across suppliers
- Automates the order submission process on supplier websites

### 1.4 Business Value

| Benefit | Impact |
|---------|--------|
| Time savings | Reduce ordering time by 60-70% |
| Cost savings | 5-15% savings through price optimization |
| Error reduction | Eliminate manual order entry mistakes |
| Visibility | Centralized spend tracking and reporting |

---

## 2. Stakeholders

| Role | Responsibilities | Concerns |
|------|------------------|----------|
| Restaurant Owner/Manager | Primary user; manages orders, budgets | Cost, ease of use, reliability |
| Kitchen Manager/Chef | Creates order lists, monitors inventory | Product availability, order accuracy |
| Accountant/Bookkeeper | Reviews order history, costs | Reporting, audit trail |
| System Administrator | Manages user accounts, supplier configs | Security, maintenance |

---

## 3. Scope

### 3.1 In Scope

- User authentication and account management
- Secure storage of supplier portal credentials
- Automated login to supplier websites via browser automation
- Two-factor authentication handling for supplier sites
- Price scraping from supported supplier sites
- Order list creation, editing, and management
- Price comparison display across suppliers
- Automated order placement on supplier sites
- Order history and status tracking
- Multi-location support (scalable)

### 3.2 Out of Scope (Phase 1)

- Mobile native applications (web-responsive only)
- Inventory management integration
- Invoice reconciliation
- Supplier payment processing
- API integrations with suppliers (unless offered)
- Analytics and forecasting

### 3.3 Supported Suppliers (Initial)

1. US Foods (usfoods.com)
2. Chef's Warehouse (chefswarehouse.com)
3. What Chefs Want (whatchefswant.com)

---

## 4. Functional Requirements

### 4.1 User Management

| ID | Requirement | Priority |
|----|-------------|----------|
| UM-01 | System shall allow users to register with email and password | Must Have |
| UM-02 | System shall allow users to log in and log out | Must Have |
| UM-03 | System shall allow users to reset forgotten passwords | Must Have |
| UM-04 | System shall support multiple user roles (Admin, Manager, User) | Should Have |
| UM-05 | System shall allow users to manage their profile information | Should Have |

### 4.2 Location Management

| ID | Requirement | Priority |
|----|-------------|----------|
| LM-01 | System shall allow users to create multiple restaurant locations | Must Have |
| LM-02 | System shall associate supplier credentials with specific locations | Must Have |
| LM-03 | System shall allow users to switch between locations | Must Have |
| LM-04 | System shall maintain separate order history per location | Must Have |

### 4.3 Supplier Credential Management

| ID | Requirement | Priority |
|----|-------------|----------|
| SC-01 | System shall allow users to store credentials for each supported supplier | Must Have |
| SC-02 | System shall encrypt all stored credentials using AES-256 encryption | Must Have |
| SC-03 | System shall validate credentials by attempting login upon save | Should Have |
| SC-04 | System shall display credential status (Active, Expired, Failed) | Must Have |
| SC-05 | System shall allow users to update or remove stored credentials | Must Have |
| SC-06 | System shall never display plaintext passwords after initial entry | Must Have |

### 4.4 Supplier Authentication (SSO)

| ID | Requirement | Priority |
|----|-------------|----------|
| SA-01 | System shall automate login to supplier websites using stored credentials | Must Have |
| SA-02 | System shall maintain session state to minimize re-authentication | Must Have |
| SA-03 | System shall detect session expiration and re-authenticate automatically | Must Have |
| SA-04 | System shall handle MFA/CAPTCHA challenges gracefully (notify user) | Should Have |
| SA-05 | System shall log all authentication attempts for audit purposes | Must Have |
| SA-06 | System shall retry failed logins up to 3 times before marking as failed | Should Have |

### 4.5 Product Catalog

| ID | Requirement | Priority |
|----|-------------|----------|
| PC-01 | System shall maintain a canonical product catalog | Must Have |
| PC-02 | System shall map supplier-specific products to canonical products | Must Have |
| PC-03 | System shall store product attributes: name, category, unit size, UPC | Must Have |
| PC-04 | System shall allow users to search products by name, category, or SKU | Must Have |
| PC-05 | System shall allow manual product mapping when automatic fails | Should Have |
| PC-06 | System shall support fuzzy matching for product name similarities | Could Have |

### 4.6 Price Scraping

| ID | Requirement | Priority |
|----|-------------|----------|
| PS-01 | System shall scrape current prices from connected supplier accounts | Must Have |
| PS-02 | System shall update prices on a configurable schedule (default: daily) | Must Have |
| PS-03 | System shall allow on-demand price refresh for specific products | Should Have |
| PS-04 | System shall record price history with timestamps | Should Have |
| PS-05 | System shall detect and flag significant price changes (>10%) | Could Have |
| PS-06 | System shall track product availability (in-stock/out-of-stock) | Must Have |
| PS-07 | System shall handle scraping errors gracefully and log failures | Must Have |

### 4.7 Order List Management

| ID | Requirement | Priority |
|----|-------------|----------|
| OL-01 | System shall allow users to create named order lists | Must Have |
| OL-02 | System shall allow users to add products with quantities to lists | Must Have |
| OL-03 | System shall allow users to edit and delete order lists | Must Have |
| OL-04 | System shall allow users to duplicate existing order lists | Should Have |
| OL-05 | System shall display total estimated cost per list | Must Have |
| OL-06 | System shall allow categorization/tagging of order lists | Could Have |
| OL-07 | System shall support unlimited order lists per user | Must Have |

### 4.8 Price Comparison

| ID | Requirement | Priority |
|----|-------------|----------|
| CP-01 | System shall display prices for order list items across all suppliers | Must Have |
| CP-02 | System shall highlight the lowest price for each item | Must Have |
| CP-03 | System shall calculate total cost per supplier for entire list | Must Have |
| CP-04 | System shall show potential savings vs. highest-priced supplier | Should Have |
| CP-05 | System shall indicate when a product is unavailable at a supplier | Must Have |
| CP-06 | System shall allow filtering/sorting by price, supplier, availability | Should Have |
| CP-07 | System shall show last price update timestamp | Must Have |

### 4.9 Order Placement

| ID | Requirement | Priority |
|----|-------------|----------|
| OP-01 | System shall allow users to select supplier for order placement | Must Have |
| OP-02 | System shall automate adding items to cart on supplier website | Must Have |
| OP-03 | System shall automate checkout process on supplier website | Must Have |
| OP-04 | System shall capture and store order confirmation number | Must Have |
| OP-05 | System shall allow users to review order before final submission | Must Have |
| OP-06 | System shall handle order submission errors and notify user | Must Have |
| OP-07 | System shall support partial orders (skip unavailable items) | Should Have |
| OP-08 | System shall allow cancellation before final submission | Must Have |

### 4.10 Order History

| ID | Requirement | Priority |
|----|-------------|----------|
| OH-01 | System shall maintain complete order history | Must Have |
| OH-02 | System shall display order status (Pending, Submitted, Confirmed, Failed) | Must Have |
| OH-03 | System shall store order details: items, quantities, prices, total | Must Have |
| OH-04 | System shall allow filtering orders by date, supplier, status | Should Have |
| OH-05 | System shall allow reordering from a previous order | Should Have |
| OH-06 | System shall export order history to CSV | Could Have |

### 4.11 Supplier Requirements & Validation

| ID | Requirement | Priority |
|----|-------------|----------|
| SR-01 | System shall store and enforce order minimum requirements for each supplier | Must Have |
| SR-02 | System shall store and enforce delivery day/cutoff time requirements per supplier | Must Have |
| SR-03 | System shall validate orders against supplier minimums before submission | Must Have |
| SR-04 | System shall display clear error messages when order minimums are not met | Must Have |
| SR-05 | System shall show how much more is needed to meet order minimum | Must Have |
| SR-06 | System shall track product-specific minimum order quantities (case minimums, etc.) | Should Have |
| SR-07 | System shall validate delivery address is within supplier service area | Should Have |
| SR-08 | System shall handle supplier-specific account restrictions (credit holds, etc.) | Must Have |
| SR-09 | System shall detect and report item quantity limits (max per order) | Should Have |
| SR-10 | System shall track supplier-specific order deadlines (cutoff times) | Must Have |
| SR-11 | System shall warn users when approaching order cutoff time | Should Have |
| SR-12 | System shall handle promotional/contract pricing requirements | Could Have |

### 4.12 Error Handling & Recovery

| ID | Requirement | Priority |
|----|-------------|----------|
| EH-01 | System shall provide specific, actionable error messages for all failure scenarios | Must Have |
| EH-02 | System shall gracefully handle supplier website unavailability | Must Have |
| EH-03 | System shall detect and report when items become unavailable during checkout | Must Have |
| EH-04 | System shall detect price changes between comparison and order placement | Must Have |
| EH-05 | System shall allow users to review and accept price changes before proceeding | Must Have |
| EH-06 | System shall handle partial order failures (some items failed, others succeeded) | Should Have |
| EH-07 | System shall provide order rollback/cancellation when possible | Should Have |
| EH-08 | System shall log all errors with sufficient detail for troubleshooting | Must Have |
| EH-09 | System shall notify users of failed background jobs affecting their orders | Must Have |
| EH-10 | System shall detect CAPTCHA/bot detection and notify user for manual intervention | Must Have |

### 4.13 Supplier Two-Factor Authentication Handling

| ID | Requirement | Priority |
|----|-------------|----------|
| 2FA-01 | System shall detect when a supplier site requests 2FA during login | Must Have |
| 2FA-02 | System shall pause automation and prompt user to enter 2FA code in real-time | Must Have |
| 2FA-03 | System shall support SMS-based 2FA codes from suppliers | Must Have |
| 2FA-04 | System shall support TOTP/authenticator app codes from suppliers | Must Have |
| 2FA-05 | System shall support email-based 2FA codes from suppliers | Should Have |
| 2FA-06 | System shall provide a timeout window for 2FA code entry (default: 5 minutes) | Must Have |
| 2FA-07 | System shall allow user to cancel 2FA and abort the operation | Must Have |
| 2FA-08 | System shall retry failed 2FA code submissions up to 3 times | Should Have |
| 2FA-09 | System shall remember trusted device status when supplier supports it | Should Have |
| 2FA-10 | System shall notify user via browser notification when 2FA is required | Should Have |
| 2FA-11 | System shall log all 2FA events for audit purposes | Must Have |
| 2FA-12 | System shall handle 2FA during both login and checkout processes | Must Have |

---

## 5. Non-Functional Requirements

### 5.1 Security

| ID | Requirement | Priority |
|----|-------------|----------|
| SEC-01 | All credentials must be encrypted at rest using AES-256 | Must Have |
| SEC-02 | All data in transit must use TLS 1.2+ (HTTPS) | Must Have |
| SEC-03 | Passwords must meet complexity requirements (min 8 chars, mixed case, numbers) | Must Have |
| SEC-04 | Sessions must timeout after 30 minutes of inactivity | Must Have |
| SEC-05 | Failed login attempts must be rate-limited (5 attempts per 15 minutes) | Must Have |
| SEC-06 | Audit logs must be maintained for all sensitive operations | Should Have |
| SEC-07 | Database backups must be encrypted | Must Have |

### 5.2 Performance

| ID | Requirement | Priority |
|----|-------------|----------|
| PRF-01 | Page load time must be under 3 seconds | Must Have |
| PRF-02 | Price comparison queries must complete in under 5 seconds | Should Have |
| PRF-03 | System must support 100 concurrent users | Should Have |
| PRF-04 | Background jobs must not impact foreground performance | Must Have |
| PRF-05 | Order placement must complete within 60 seconds | Should Have |

### 5.3 Reliability

| ID | Requirement | Priority |
|----|-------------|----------|
| REL-01 | System uptime must be 99.5% (excluding scheduled maintenance) | Should Have |
| REL-02 | Failed background jobs must retry automatically (3 attempts) | Must Have |
| REL-03 | System must gracefully degrade when supplier sites are unavailable | Must Have |
| REL-04 | Data must be backed up daily with 30-day retention | Must Have |

### 5.4 Usability

| ID | Requirement | Priority |
|----|-------------|----------|
| USB-01 | Interface must be responsive (desktop, tablet, mobile) | Should Have |
| USB-02 | Critical actions must have confirmation dialogs | Must Have |
| USB-03 | Error messages must be clear and actionable | Must Have |
| USB-04 | System must provide feedback for long-running operations | Must Have |

### 5.5 Maintainability

| ID | Requirement | Priority |
|----|-------------|----------|
| MNT-01 | Code must follow Ruby/Rails style guidelines | Should Have |
| MNT-02 | Test coverage must be minimum 80% | Should Have |
| MNT-03 | Scraper modules must be independently updateable | Must Have |
| MNT-04 | Configuration must be environment-based (dev, staging, prod) | Must Have |

---

## 6. Constraints

| Type | Constraint |
|------|------------|
| Technical | Must use Ruby on Rails 7.1+ with PostgreSQL |
| Technical | Must use headless browser for web scraping (no official APIs available) |
| Legal | Web scraping may violate supplier ToS; user assumes responsibility |
| Operational | Supplier website changes may break scrapers; requires ongoing maintenance |
| Business | Initial support limited to 3 suppliers |

---

## 7. Assumptions

1. Users have existing accounts with supported suppliers
2. Supplier websites remain relatively stable (no major redesigns)
3. Suppliers do not implement aggressive bot detection
4. Users are comfortable storing their supplier credentials in a third-party system
5. Internet connectivity is reliable at user locations
6. Users have modern web browsers (Chrome, Firefox, Safari, Edge - latest 2 versions)

---

## 8. Risks

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Supplier blocks automated access | Medium | High | Implement rate limiting, rotate user agents, use residential proxies |
| Supplier website redesign breaks scraper | High | Medium | Modular scraper design, monitoring, rapid response process |
| Credential breach | Low | Critical | Strong encryption, access controls, audit logging, security reviews |
| User violates supplier ToS | Medium | Medium | Clear user agreements, disclaimer of liability |
| Product mapping inaccuracy | Medium | Low | Manual override capability, user feedback loop |

---

## 9. Success Criteria

| Metric | Target |
|--------|--------|
| User adoption | 10 active users within 3 months of launch |
| Order placement success rate | >95% |
| Price data accuracy | >98% |
| User-reported time savings | >50% reduction in ordering time |
| System availability | >99% uptime |

---

## 10. Glossary

| Term | Definition |
|------|------------|
| SSO | Single Sign-On; in this context, automated authentication to supplier portals |
| 2FA | Two-Factor Authentication; additional verification step requiring a code |
| Scraping | Automated extraction of data from websites |
| Canonical Product | A standardized product record that maps to supplier-specific variants |
| Order List | A saved collection of products and quantities for reuse |
| Supplier Credential | Username and password for a supplier's ordering portal |
| TOTP | Time-based One-Time Password; codes generated by authenticator apps |

---

## 11. Approval

| Role | Name | Signature | Date |
|------|------|-----------|------|
| Project Sponsor | | | |
| Product Owner | | | |
| Technical Lead | | | |

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-26 | | Initial draft |
