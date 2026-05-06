import { OWNER_STEPS,   OWNER_FLOW   } from "onboarding/steps/owner"
import { CHEF_STEPS,    CHEF_FLOW    } from "onboarding/steps/chef"
import { MANAGER_STEPS, MANAGER_FLOW } from "onboarding/steps/manager"

const REGISTRY = {
  owner:   { steps: OWNER_STEPS,   flow: OWNER_FLOW   },
  chef:    { steps: CHEF_STEPS,    flow: CHEF_FLOW    },
  manager: { steps: MANAGER_STEPS, flow: MANAGER_FLOW },
}

export function flowFor(role) {
  return REGISTRY[role]?.flow || []
}

export function stepsFor(role) {
  return REGISTRY[role]?.steps || {}
}

// Returns the next step name in the flow, or null if currentStep is
// the last (or unknown) step.
//
// Note: we intentionally do NOT auto-skip steps the user has already
// completed in DB state. Skipping makes the indicator jump (e.g. 1/6 →
// 3/6) which reads as a bug. Each step's body copy is descriptive
// ("here's where this lives") so it reads fine even if the underlying
// action is already done.
export function nextStepName(role, currentStep) {
  const flow = flowFor(role)
  const i = flow.indexOf(currentStep)
  if (i === -1 || i + 1 >= flow.length) return null
  return flow[i + 1]
}

export function isLastStep(role, currentStep) {
  const flow = flowFor(role)
  return flow.length > 0 && flow[flow.length - 1] === currentStep
}
