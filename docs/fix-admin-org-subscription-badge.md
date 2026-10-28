# Admin Organizations list: show the current subscription (Oct 28 2026)

## What was wrong

Admin → Organizations showed **Canceled** for Alfios buon cibo (org 7), which pays for a live subscription.

Org 7 has two subscription rows: the old Stripe test-mode subscription canceled Jun 4 (when it went complimentary) and the live one from switching to paid. The list picked its badge with

```erb
org.subscriptions.find { |s| %w[active trialing past_due canceled].include?(s.status) }
```

which returns the first matching row in whatever order Postgres hands back the preloaded association, in practice the oldest. The Jun 4 canceled row won. Any org that cancels and later resubscribes would show the same thing.

The org detail page was never affected: it queries `with_access` newest-first.

## The fix

`Organization#display_subscription`: the newest subscription with access (active, trialing, past_due), else the newest canceled one, else nil ("None"). It sorts the loaded association in Ruby, so the list's `includes(:subscriptions)` still covers it and there's no query per row. Statuses that were hidden before (`incomplete`, `unpaid`, ...) still show as None, same as before.

Regression specs in `spec/requests/admin_spec.rb` (GET /admin/organizations) read the rendered badge cell: old canceled + newer active shows Active; canceled only shows Canceled; never subscribed shows None. The first one fails on the old view with `got: "Canceled"`.

## Not changed

- The detail page, `current_subscription`, `subscribed?` and every access check. Nobody's access or billing changes; this is a label on one admin page.
- The other rows were already right: Tres Noches and BIG ICE had their test subscriptions retired by the Oct 19 cutover, The Empanada's Box's subscription is canceled.

## The second "Alfios Buon Cibo" (org 10)

It showed **None** correctly. It's a separate org that binskimj@gmail.com created on Aug 24 by signing up instead of being invited into org 7: 1 member, 0 orders, no subscription, no comp. Carmin asked on Oct 28 to delete it and that user so it stops causing confusion.

There's no admin delete button, and `Organization#destroy` alone still doesn't clear CRM onboardings, CRM leads or users parked on the org (see the Aug 2026 cascade notes), so the deletion is a one-off script run on prod. It:

- refuses to run unless the user belongs to exactly one org, owns it, it has one member, it isn't org 7, and neither has orders, subscriptions or invoices, and the user isn't a CRM salesperson;
- clears invitations, the org's CRM onboarding, unlinks CRM leads, and un-parks users, then destroys the org and the user in one transaction;
- scans every table for any column still pointing at either id and rolls back if one does;
- has a dry-run mode that does all of it and then rolls back.

**Done Oct 28 2026** (dry run first, then applied with Carmin's go-ahead). What it found and removed:

- User 19, binskimj@gmail.com: signed up and signed in once on Aug 24, never again. Only membership: owner of org 10.
- Org 10, "Alfios Buon Cibo " (trailing space): 1 location, its default matched list, no supplier logins, orders, subscriptions or Stripe customer.
- 1 invitation from org 10: michael@alfios-cincy.com as chef, sent Aug 24, never accepted, expired Aug 31.
- Kept: billing event 47 (`customer.created`, Aug 24, from the test-mode era), with its user link cleared.

Afterwards neither id appeared in any table, and org 7 still had its 9 members.
