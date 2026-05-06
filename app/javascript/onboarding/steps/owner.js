import { SHARED_STEPS } from "onboarding/steps/shared"

// Owner-only steps — adds the setup-phase reminders (org/restaurant/team)
// and the promote-list training step that only owners can perform.
//
// The owner wizard runs AFTER the legacy hard-gate is satisfied, so the
// org/restaurant/team steps are training reminders ("here's where these
// settings live going forward") rather than blocking setup. The wizard
// auto-skips them via computed_completed_steps when their underlying DB
// state already exists.
const OWNER_ONLY_STEPS = {
  organization: {
    title: "Organization settings",
    body: "Your organization is the top-level container — restaurants, team, suppliers all live under it. You can update your org details, name, and timezone here any time.",
    image: "team",
    spotlight: "menu-settings",
    primaryCta: "Got it →",
  },

  restaurant: {
    title: "Restaurants",
    body: "Each location is a delivery address. Add as many as you need — every order is tied to one, and you can switch between them from the location pill in the top nav.",
    image: "restaurants",
    spotlight: "menu-restaurants",
    primaryCta: "Got it →",
  },

  team: {
    title: "Team",
    body: "Invite managers (read-only across locations) and chefs (assigned to one location) so your team can run orders for their restaurants.",
    image: "team",
    spotlight: "menu-team",
    primaryCta: "Got it →",
  },

  "train-promote": {
    title: "Promote a list (optional)",
    body: "Any matched list can be promoted org-wide. Once promoted, it becomes the canonical comparison list every chef and manager across every restaurant sees. If you don't promote one, each location uses its own matched list instead.",
    image: "product-matching",
    spotlight: "menu-product-matching",
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
