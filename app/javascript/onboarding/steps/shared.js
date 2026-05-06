// Shared step descriptors used across multiple wizard roles.
//
// Each step describes WHAT to render:
//   - title
//   - body (HTML, rendered via innerHTML)
//   - image (optional key, resolved server-side via image_paths)
//   - spotlight (DOM target id, or array of fallback ids — first match wins)
//   - primaryCta (button label)
//
// `body` is HTML, so all values must be authored here, never user input.
//
// `spotlight` matches a `[data-onboarding-target="..."]` attribute on a
// DOM element. Targets prefixed with `menu-` live inside the avatar
// dropdown — the wizard opens it automatically before highlighting.
// `null` means "no spotlight, just show the modal centered."

export const SHARED_STEPS = {
  welcome: {
    title: "Welcome to EnPlace Pro",
    body: "Quick tour to show you around. You can dismiss this any time and pick it back up later from the avatar menu.",
    spotlight: null,
    primaryCta: "Start tour →",
  },

  suppliers: {
    title: "Connect your suppliers",
    body: "Pick a supplier below to connect. We'll bring you back here after each save so you can connect more — or tap <strong>Continue tour</strong> when you're done.",
    spotlight: "menu-supplier-creds",
    primaryCta: "Continue tour →",
  },

  "train-orderlists": {
    title: "Order Lists",
    body: "Lists are reusable shopping templates. Create one per recipe, per delivery day, or per supplier — then reuse them every week instead of starting from scratch.",
    image: "order-lists",
    spotlight: "nav-orderlists",
    primaryCta: "Got it →",
  },

  "train-neworder": {
    title: "Place an order",
    body: "Tap <strong>+ NEW ORDER</strong>, pick a list, then we verify live prices with each supplier and split items by best price. Nothing leaves until you tap Submit Order for each supplier.",
    image: "order-review",
    spotlight: "nav-neworder",
    primaryCta: "Got it →",
  },

  "train-matching": {
    title: "Product Matching",
    body: "We match the same product across suppliers so you can compare prices on identical items. The grid shows the best price per supplier with a BEST badge.",
    image: "aggregated-show",
    spotlight: "menu-product-matching",
    primaryCta: "Got it →",
  },

  "train-orderhistory": {
    title: "Order History",
    body: "Every order — drafts, submitted, processing, delivered — lives here. Click any order to verify, edit, or re-place it.",
    image: "order-history",
    spotlight: "nav-orderhistory",
    primaryCta: "Got it →",
  },

  "train-reports": {
    title: "Reports",
    body: "Spending trends, savings tracking, supplier and restaurant breakdowns — everything you need to see how performance is changing month over month.",
    image: "reports",
    spotlight: "nav-reports",
    primaryCta: "Got it →",
  },

  done: {
    title: "You're all set",
    body: "You can re-launch this tour any time from the avatar menu. Happy ordering.",
    spotlight: null,
    primaryCta: "Done",
  },
}
