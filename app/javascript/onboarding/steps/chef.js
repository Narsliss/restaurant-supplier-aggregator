import { SHARED_STEPS } from "onboarding/steps/shared"

// Chef wizard reuses every shared step verbatim. No chef-specific overrides
// today — if any step copy ever needs to differ for chefs, override it
// inside this object: { ...SHARED_STEPS, suppliers: {...} }.
export const CHEF_STEPS = { ...SHARED_STEPS }

export const CHEF_FLOW = [
  "welcome",
  "suppliers",
  "train-orderlists",
  "train-neworder",
  "train-matching",
  "done",
]
