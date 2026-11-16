# Admin role (support staff)

**Date:** Nov 16 2026 · **Status:** built on branch `admin-role`, not shipped

## Why

Carmin wants to give one other person the admin dashboard. The app allows exactly
one `super_admin` on purpose: `User.super_admin` picks "the" super admin for every
alert email (scraping, catalog import, billing, seat sync, match health) and for
the deep catalog import's credential choice. A second super admin would split
those alerts unpredictably. So instead of a second super admin there is a new,
narrower system role: **`admin`**.

## Access types (users.role)

| Role | Gets |
|---|---|
| `user` | The regular app, through organization memberships |
| `salesperson` | The CRM only |
| `admin` | The admin dashboard, the support actions, read-only "view as user" |
| `super_admin` | Everything. Still only one, still the only one who gets alerts |

`User#admin_access?` is true for `admin` and `super_admin`. The `/admin` routes
and `Admin::BaseController` check that. `super_admin?` is unchanged everywhere
else, so an admin gets none of the super admin's organization-wide access in
the regular app.

## What an admin can do

- Open: Dashboard, Organizations (list and detail), Revenue, Operations, Usage,
  Supplier Users (list), user detail pages.
- Support actions: unlock an account, send a password reset, resend an invite,
  extend a trial.
- View as a user (impersonate). Read-only as for the super admin:
  `ImpersonationGuard` blocks every non-GET request. An admin can't view as the
  super admin or another admin. Note: opening some pages while viewing as a chef
  (e.g. the review page) still starts price checks and delivery-date fetches with
  that chef's supplier logins, exactly as when the super admin does it.

## Super admin only (server-guarded, buttons hidden for admins)

- Suspend / reactivate an organization
- Grant / revoke free access; cancel a subscription
- Stripe test-mode cleanup (`/admin/billing_cutover`, page and action)
- Changing a supplier's morning stock mode (buttons shown disabled)
- Creating salespeople; inviting supplier portal users
- Jobs dashboard (`/jobs`), CRM, Products, "Exit to App"
- All alert emails

An admin sent to a super-admin-only action is redirected to the admin dashboard
with "Only the super admin can do that."

## Regular app

Admins have no restaurant. `ApplicationController#redirect_admin_to_admin_panel`
sends them from any regular-app page to `/admin` (account settings and sign-out
still work), the same way salespeople are kept in the CRM. While viewing as a
user, `current_user` is that user, so the redirect doesn't apply.

## Making someone an admin

There is no button; it's a one-off. On production (Rails console):

```ruby
# Existing account:
User.find_by!(email: "person@example.com").update!(role: "admin")

# New account (they set their own password from the reset email):
u = User.create!(email: "person@example.com", first_name: "First", last_name: "Last",
                 role: "admin", password: SecureRandom.hex(24))
u.send_reset_password_instructions
```

Don't promote someone who belongs to a restaurant: as an admin they'd be
redirected out of the regular app and lose access to it.

To remove: `update!(role: "user")`.

No migration: `users.role` is a plain string; the unique index only covers
`super_admin`.

## Tests

`spec/requests/admin_role_spec.rb`: pages admins can open; the regular-app
redirect; every super-admin-only action refused and its button hidden; the super
admin still sees everything; unlock and password reset work; view-as-user is
read-only, returns to the dashboard, and refuses super admin/admin targets;
multiple admins don't change `User.super_admin`.
