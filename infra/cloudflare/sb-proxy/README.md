# Supabase proxy on a custom domain

A Cloudflare Worker, `vahtahoz-sb-proxy`, forwards the configured custom Supabase domain to the project's Supabase origin. Account identifiers and deployment credentials belong in private operator configuration.

## Purpose

Some Russian networks cannot reach `*.supabase.co` without a VPN. The Cloudflare-hosted page loads, but its first direct database request times out, preventing sign-in. Moving the site to Cloudflare alone does not fix direct client requests to Supabase. The original check reproduced this on a phone; the same request on a VPN-connected Mac completed in 1.6 seconds.

## Deployment

```sh
cd infra/cloudflare/sb-proxy
CLOUDFLARE_ACCOUNT_ID=... \
CLOUDFLARE_EMAIL=... CLOUDFLARE_API_KEY=... npx wrangler deploy
```

The hostname is a Workers Custom Domain; Cloudflare manages DNS and the certificate.

## Recorded release state

**Stable was switched in v222 on 2026-08-01.** The change was `CLOUD_CFG.url` in `vahtahoz.html`; the shell no longer used direct `supabase.co` links. Sessions remained valid because the explicit `storageKey: NS+"vahtahoz_auth"` does not depend on the origin. Previously installed builds continue using their embedded direct URL.

**Beta on main (v214) was deliberately left unchanged.** The same URL change was intended to arrive with promotion of the round-eleven batch; editing beta separately would have been overwritten by that branch's full-file merge.

The recorded live verification checked the proxy URL, build v222 and service-worker control. A page-origin request, including preflight, reached `POST /auth/v1/token` and returned `invalid_credentials` for a deliberately incorrect password.

**Rollback:** restore the direct origin in `CLOUD_CFG.url`, increment versions and deploy.

## Why a separate host

`sw.js` intercepts same-origin GET requests and can serve cached responses after network failure. Placing database requests on that origin could present stale warehouse balances as current. A separate host avoids interception and requires no `sw.js` change.

## Recorded post-deployment checks

- `/`: `vahtahoz sb-proxy ok`.
- `/rest/v1/`: ten consecutive 401 responses, matching direct unauthenticated requests.
- `/auth/v1/token?grant_type=password`: incorrect password returned 400 through both routes.
- `/functions/v1/manage-user`: reached the function and returned `{"error":"no auth"}`.
- `OPTIONS` with the application Origin: 200; `access-control-allow-origin: *` passed through.
- `/realtime/v1/websocket`: `101 Switching Protocols`; the app uses `cloud.sb.channel(...)`.
- Unlisted `/evil/path`: 404; the route allowlist prevents an open proxy.

## Remaining considerations

- **IP rate limits:** Supabase sees Cloudflare addresses. IP-based GoTrue limits may group users together; the application's email-keyed `auth_rate` limiter is unaffected. Investigate if users report excessive-attempt errors.
- Edge caching is explicitly disabled with `cacheTtl: 0`. PostgREST responses lack `Cache-Control`; caching a GET could serve it to another user. Any future caching must use an explicit route policy.
