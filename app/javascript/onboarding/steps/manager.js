import { SHARED_STEPS } from "onboarding/steps/shared"

// Manager wizard is read-only training — no setup phase, no order
// placement (managers don't run orders). Just orientation to the
// reporting and order-tracking surfaces they actually use.
export const MANAGER_STEPS = { ...SHARED_STEPS }

export const MANAGER_FLOW = [
  "welcome",
  "train-orderhistory",
  "train-reports",
  "train-orderlists",
  "done",
]
