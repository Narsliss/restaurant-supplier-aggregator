// Shared step descriptors used across multiple wizard roles.
//
// Each step describes WHAT to render:
//   - phase    : "intro" | "setup" | "tour" | "done"  (drives the badge in the header)
//   - optional : boolean — adds the "OPTIONAL" suffix in the badge (default true)
//   - title    : heading
//   - body     : HTML, rendered via innerHTML (author-only, never user input)
//   - image    : optional asset key (resolved server-side via image_paths)
//   - spotlight: DOM target id, or array of fallback ids (first match wins)
//   - livesAt  : breadcrumb shown in the header — e.g. ["Avatar", "Team"]
//   - primaryCta: primary button label
//
// `spotlight` matches a `[data-onboarding-target="..."]` attribute on a
// DOM element. Targets prefixed with `menu-` live inside the avatar
// dropdown — the wizard opens it automatically before highlighting.

export const SHARED_STEPS = {
  welcome: {
    phase: "intro",
    optional: false,
    title: "Welcome to EnPlace Pro",
    body: "Quick tour to show you around. You can dismiss this any time and pick it back up later from the avatar menu.",
    spotlight: null,
    livesAt: null,
    primaryCta: "Start tour →",
  },

  suppliers: {
    phase: "setup",
    optional: true,
    title: "Connect your suppliers",
    body: "Pick a supplier below to connect. We'll bring you back here after each save so you can connect more — or tap <strong>Continue tour</strong> when you're done.",
    spotlight: "menu-supplier-creds",
    livesAt: ["Avatar", "Supplier Credentials"],
    primaryCta: "Continue tour →",
  },

  "train-orderlists": {
    phase: "tour",
    optional: true,
    title: "Order Lists",
    body: "Lists are reusable shopping templates. Create one per recipe, per delivery day, or per supplier — then reuse them every week instead of starting from scratch.",
    image: "order-lists",
    spotlight: "nav-orderlists",
    livesAt: ["Top Nav", "Order Lists"],
    primaryCta: "Got it →",
  },

  "train-neworder": {
    phase: "tour",
    optional: true,
    title: "Place an order",
    body: "Tap <strong>+ NEW ORDER</strong>, pick a list, then we verify live prices with each supplier and split items by best price. Nothing leaves until you tap Submit Order for each supplier.",
    image: "order-review",
    spotlight: "nav-neworder",
    livesAt: ["Top Nav", "+ NEW ORDER"],
    primaryCta: "Got it →",
  },

  "train-matching": {
    phase: "tour",
    optional: true,
    title: "Product Matching",
    body: "We match the same product across suppliers so you can compare prices on identical items. The grid shows the best price per supplier with a BEST badge.",
    image: "aggregated-show",
    spotlight: "menu-product-matching",
    livesAt: ["Avatar", "Product Matching"],
    primaryCta: "Got it →",
  },

  "train-orderhistory": {
    phase: "tour",
    optional: true,
    title: "Order History",
    body: "Every order — drafts, submitted, processing, delivered — lives here. Click any order to verify, edit, or re-place it.",
    image: "order-history",
    spotlight: "nav-orderhistory",
    livesAt: ["Top Nav", "Order History"],
    primaryCta: "Got it →",
  },

  "train-reports": {
    phase: "tour",
    optional: true,
    title: "Reports",
    body: "Spending trends, savings tracking, supplier and restaurant breakdowns — everything you need to see how performance is changing month over month.",
    image: "reports",
    spotlight: "nav-reports",
    livesAt: ["Top Nav", "Reports"],
    primaryCta: "Got it →",
  },

  done: {
    phase: "done",
    optional: false,
    title: "You're all set",
    body: "You can re-launch this tour any time from the avatar menu. Happy ordering.",
    spotlight: null,
    livesAt: null,
    primaryCta: "Done",
  },
}
