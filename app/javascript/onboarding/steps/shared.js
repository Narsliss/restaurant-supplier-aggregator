// Shared step descriptors used across multiple wizard roles.
//
// Each step describes WHAT to render (title, body, which DOM element to
// spotlight). The role's flow array decides WHEN — see ./owner.js,
// ./chef.js, ./manager.js.
//
// `body` may contain HTML (for embedded screenshots/links). It is rendered
// via innerHTML, so all values must be authored here, never user input.
//
// `spotlight` matches a `[data-onboarding-target="..."]` attribute on a
// DOM element. Targets prefixed with `menu-` live inside the avatar
// dropdown — the wizard opens it automatically before highlighting.
// `null` means "no spotlight, just show the modal centered."

export const SHARED_STEPS = {
  welcome: {
    title: "Welcome to EnPlace Pro",
    body: "Quick tour to show you around. You can dismiss this any time and pick it back up from the avatar menu.",
    spotlight: null,
    primaryCta: "Start tour →",
  },

  suppliers: {
    title: "Connect your suppliers",
    body: "Link your supplier accounts so we can pull in pricing and order guides. You can connect them now or skip and come back later.",
    spotlight: "menu-supplier-creds",
    primaryCta: "Got it →",
  },

  "train-orderlists": {
    title: "Order Lists",
    body: "Lists are reusable shopping templates. Create one per recipe or per delivery day, then reuse them every week.",
    spotlight: "nav-orderlists",
    primaryCta: "Got it →",
  },

  "train-neworder": {
    title: "Place an order",
    body: "Tap <strong>+ NEW ORDER</strong>, pick a list, review live prices side-by-side, then submit per supplier. Nothing leaves until you confirm.",
    spotlight: "nav-neworder",
    primaryCta: "Got it →",
  },

  "train-matching": {
    title: "Product Matching",
    body: "We match the same product across suppliers so you can compare prices on identical items.",
    spotlight: "menu-product-matching",
    primaryCta: "Got it →",
  },

  "train-orderhistory": {
    title: "Order History",
    body: "Every order — drafts, submitted, processing, delivered — lives here. Click any to verify, edit, or re-place.",
    spotlight: "nav-orderhistory",
    primaryCta: "Got it →",
  },

  "train-reports": {
    title: "Reports",
    body: "Spending trends, savings, supplier breakdowns. Everything you need to track performance over time.",
    spotlight: "nav-reports",
    primaryCta: "Got it →",
  },

  done: {
    title: "You're all set",
    body: "You can re-launch this tour any time from the avatar menu.",
    spotlight: null,
    primaryCta: "Done",
  },
}
