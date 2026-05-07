import { SHARED_STEPS } from "onboarding/steps/shared"

// Owner-only steps — adds the setup-phase reminders (org/restaurant/team)
// and the promote-list training step that only owners can perform.
//
// The owner wizard runs AFTER the legacy hard-gate is satisfied, so the
// org/restaurant/team steps are training reminders ("here's where these
// settings live going forward") rather than blocking setup.
const OWNER_ONLY_STEPS = {
  organization: {
    phase: "setup",
    optional: true,
    title: "Organization settings",
    body: "Your organization is the top-level container — restaurants, team, suppliers all live under it. Update your org details below, or skip and come back to this any time.",
    formUrl: "/organization/edit?from_wizard=1",
    spotlight: "menu-settings",
    livesAt: ["Avatar", "Settings"],
    primaryCta: "Skip →",
  },

  restaurant: {
    phase: "setup",
    optional: true,
    title: "Add a restaurant",
    body: "Each location is a delivery address. Add another below, or skip if you've already added what you need — you can manage them any time on the Restaurants page.",
    formUrl: "/locations/new?from_wizard=1",
    spotlight: "menu-restaurants",
    livesAt: ["Avatar", "Restaurants"],
    primaryCta: "Skip →",
  },

  team: {
    phase: "setup",
    optional: true,
    title: "Invite your team",
    body: "Invite a manager (read-only across locations) or a chef (assigned to one location) below. Or skip and add them later.",
    formUrl: "/organization/invitations/new?from_wizard=1",
    spotlight: "menu-team",
    livesAt: ["Avatar", "Team"],
    primaryCta: "Skip →",
  },

  "train-promote": {
    phase: "tour",
    optional: true,
    title: "Promote a list (optional)",
    body: "Any matched list can be promoted org-wide. Once promoted, it becomes the canonical comparison list every chef and manager across every restaurant sees. If you don't promote one, each location uses its own matched list instead.",
    image: "product-matching",
    spotlight: "menu-product-matching",
    livesAt: ["Avatar", "Product Matching"],
    primaryCta: "Got it →",
  },
}

export const OWNER_STEPS = { ...SHARED_STEPS, ...OWNER_ONLY_STEPS }

// Flow order matters — matching comes right after suppliers because it's
// the foundation everything else (lists, orders) builds on. Promote sits
// next to matching since it's about promoting a matched list. Then lists,
// then placing an order, then the post-order surfaces (history, reports).
export const OWNER_FLOW = [
  "welcome",
  "organization",
  "restaurant",
  "team",
  "suppliers",
  "train-matching",
  "train-promote",
  "train-orderlists",
  "train-neworder",
  "train-orderhistory",
  "train-reports",
  "done",
]
