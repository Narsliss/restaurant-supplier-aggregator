import { SHARED_STEPS } from "onboarding/steps/shared"

// Owner-only steps — adds the setup phase (org/restaurant/team) and the
// promote-list training step that only owners can perform.
const OWNER_ONLY_STEPS = {
  organization: {
    title: "Set up your organization",
    body: "Your organization is the top-level container — restaurants, team, suppliers all live under it.",
    spotlight: "menu-settings",
    primaryCta: "Got it →",
  },

  restaurant: {
    title: "Add a restaurant",
    body: "Each location is a delivery address. Add as many as you need — every order is tied to one.",
    spotlight: "menu-restaurants",
    primaryCta: "Got it →",
  },

  team: {
    title: "Invite your team",
    body: "Add managers and chefs so they can run orders for their locations.",
    spotlight: "menu-team",
    primaryCta: "Got it →",
  },

  "train-promote": {
    title: "Promote a list (optional)",
    body: "Any matched list can be promoted org-wide. Once promoted, it's the canonical comparison list every chef and manager sees. If you don't promote one, each location uses its own matched list instead.",
    spotlight: "menu-product-matching",
    primaryCta: "Got it →",
  },
}

export const OWNER_STEPS = { ...SHARED_STEPS, ...OWNER_ONLY_STEPS }

export const OWNER_FLOW = [
  "welcome",
  "organization",
  "restaurant",
  "team",
  "suppliers",
  "train-orderlists",
  "train-neworder",
  "train-matching",
  "train-promote",
  "train-orderhistory",
  "train-reports",
  "done",
]
