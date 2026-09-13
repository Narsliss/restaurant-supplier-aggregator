# Fix: Mobile 2FA code Submit button dead on suppliers page

**Date:** 2026-09-13
**Reported by:** A chef re-validating PPO on their phone — "the button doesn't seem to be a button."

## What

On the mobile suppliers page (`app/views/supplier_credentials/index.html+mobile.erb`), the
2FA verification-code input named its Stimulus target `tfaInput`, but
`credential_validator_controller.js` declares the target as `tfaCodeInput` and
`submitCode()` reads `this.tfaCodeInputTarget` unguarded on its first line. On mobile,
tapping **Submit** (or pressing Enter in the code field) threw
`Missing target element "tfaCodeInput"` inside the click handler before any UI feedback —
the button appeared completely inert. The desktop view used the correct name, so the flow
only broke on phones.

Fix: renamed the mobile view's target to `tfaCodeInput` (one attribute).

## Why it surfaced now

Only 2FA suppliers (US Foods, PPO) go through the code-entry step; password suppliers
validate without it. PPO chefs are forced through this monthly by the Cognito 30-day
session cap, and mobile is where a chef standing in a kitchen does it.

## What did NOT work / dead ends

- The bug is not a missing controller registration (`credential-validator` is registered
  in `controllers/index.js`) and not a missing JS bundle in the mobile layout — both were
  checked first.
- First draft of the regression spec used `status: "invalid"`, which
  `SupplierCredential` rejects (valid: pending/active/expired/failed/hold); switched to
  `expired`.

## Regression coverage

`spec/requests/mobile_chef_flow_spec.rb` — "mobile suppliers page 2FA code entry" asserts
the mobile page renders `data-credential-validator-target="tfaCodeInput"` and never the
stale `"tfaInput"` name.

## Open items

- The Validate → code-entry → submit flow has no JS-level integration test; a system spec
  driving the Stimulus controller would have caught this class of target-name drift.
- Committed to `main` directly (chef-facing hotfix); `performance-integration` rebased on top.
