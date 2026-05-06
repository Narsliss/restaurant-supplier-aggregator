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
// the last (or unknown) step. Already-completed steps (e.g. organization
// when the user already created their org outside the wizard) are skipped.
export function nextStepName(role, currentStep, completedSteps = []) {
  const flow = flowFor(role)
  const i = flow.indexOf(currentStep)
  if (i === -1) return null

  for (let j = i + 1; j < flow.length; j++) {
    if (!completedSteps.includes(flow[j])) {
      return flow[j]
    }
  }
  return null
}

export function isLastStep(role, currentStep) {
  const flow = flowFor(role)
  return flow.length > 0 && flow[flow.length - 1] === currentStep
}
