# Live updates on enplacepro.app: stop pinning the Action Cable host (Oct 28 2026)

## What was wrong

Carmin sent a menu planner request on Oct 28 (event plan 11, 1:18 PM ET). The worker ran `GenerateMenuPlanJob` in 0.85s, Groq answered, and the reply was saved, but the page sat on "Generating your menu plan..." until reloaded.

The reply reaches the page over Action Cable (a websocket). `config/environments/production.rb` had:

```ruby
config.action_cable.url = 'wss://pretty-friendship-production-7e4d.up.railway.app/cable'
config.action_cable.allowed_request_origins = [
  'https://pretty-friendship-production-7e4d.up.railway.app',
  %r{https://.*\.up\.railway\.app}
]
```

Two problems, either one enough to break it:

1. **The pinned host no longer exists.** That Railway subdomain now returns Railway's `{"code":404,"message":"Application not found"}`, so the browser's websocket has nowhere to connect.
2. **enplacepro.app was never allowed.** Even while that subdomain worked, a page on enplacepro.app sends `Origin: https://enplacepro.app`, which matched neither entry, so the connection was refused. Login cookies also aren't sent to a different site, so `ApplicationCable::Connection` would have rejected it as signed out.

## How it happened

- Feb 24 2026 (fc5a41a): the app lived at the Railway subdomain, and these lines pointed at it. Correct at the time.
- Apr 7 2026 (da48dc8): email links in the same file moved to enplacepro.app. The Action Cable lines just below were left alone.
- Later: the Railway subdomain was removed from the service (date unknown).

So live updates have most likely not worked for anyone on enplacepro.app since that move. The DNS was fine; the setting was stale.

## What it affected

Everything pushed over Action Cable, in production only:

- **Menu planner replies** (`GenerateMenuPlanJob` → `Turbo::StreamsChannel`). The reply was saved and showed after a reload.
- **The 2FA code pop-up** for supplier logins (`TwoFactorChannel`, pushed from `Authentication::TwoFactorHandler` and the US Foods, Sysco and PPO scrapers). The modal in the layout starts hidden and only opens when a push arrives. Not checked: whether chefs had another way to enter the code, for example on the supplier credentials page.

The worker sends pushes through Solid Cable (a database table), which doesn't fail when nobody is listening. That's why nothing showed up in the logs.

## The fix

- Removed `config.action_cable.url`. With no URL, `action_cable_meta_tag` falls back to the mount path (`/cable`), and `@rails/actioncable` builds `wss://<the page's host>/cable`. A future domain move can't leave it behind again.
- `allowed_request_origins` is now `https://enplacepro.app` and `https://www.enplacepro.app`. Rails already accepts a connection whose Origin matches the host it arrived on (`allow_same_origin_as_host` is on by default, and in 7.1 it uses `Rack::Request#ssl?`, which follows Railway's `X-Forwarded-Proto`), so the list is a backup, not the only thing letting connections in.
- Dropped the `*.up.railway.app` rule. It accepted any site hosted on Railway, and the pattern wasn't anchored. Little was exposed (no login cookies cross-site), but nothing needs it.

Development (`ws://localhost:3000/cable`) is unchanged.

## Tests

`spec/config/production_action_cable_spec.rb` runs the production configure block against a stand-in config object, so the test app's real config isn't touched, and checks:

- no `url` is set;
- both enplacepro.app origins are allowed;
- Railway-hosted origins, including the old subdomain, are not.

All three fail against the old file and pass against the new one.

## Not verified yet

The spec can't open a real websocket through Cloudflare and Railway. After the deploy, check:

1. Send a menu planner message and watch the reply replace "Generating your menu plan..." without a reload.
2. `railway logs --service pretty-friendship --filter "origin not allowed"` stays empty.
3. Next time a supplier login asks for a code, the 2FA pop-up appears.

## Open items

- Whether the 2FA flow had a fallback while the pop-up was dead: not checked.
- The Oct 28 menu reply was 317 characters, too short for a menu, so Groq answered with text only (an answer, a question back, or the off-topic refusal). Unrelated to this fix, but worth reading once the page is reloaded.
