# IPv6 front door (Cloudflare Worker)

## Why this exists

Railway's generated `*.up.railway.app` domains have an **A record but no AAAA**:

```text
api-production-352e8.up.railway.app    IPv4: 1    IPv6: 0
```

Phones on IPv6-only mobile networks cannot reach an IPv4-only host unless the
carrier's NAT64/DNS64 translates for them. When it doesn't, the app works on
dual-stack Wi-Fi and fails on mobile data with
*"Cannot reach the server. Is the API running?"* — which real users experience
as a broken app, not as a network quirk.

`*.workers.dev` publishes both A and AAAA, so this Worker terminates the IPv6
connection and forwards to Railway over IPv4. Free, and no domain required.

Render, Koyeb and Vercel are also IPv4-only on their free domains, so moving
hosts does not solve this. Fly.io (`*.fly.dev`) is IPv6-native if you would
rather migrate than proxy.

## Deploy (dashboard, no install)

1. [dash.cloudflare.com](https://dash.cloudflare.com) → **Workers & Pages** → **Create** → **Start from Hello World**
2. Name it `speedquiz-api` → **Deploy**
3. **Edit code**, replace everything with [`worker.js`](worker.js), **Deploy**
4. **Settings → Variables** → add `ORIGIN_HOST` = your Railway host (no scheme)

You get `https://speedquiz-api.<your-subdomain>.workers.dev`.

## Deploy (CLI)

```bash
cd infrastructure/cloudflare-worker && npx wrangler deploy
```

Opens a browser for Cloudflare login on first run.

## Verify

```bash
curl -s https://speedquiz-api.<your-subdomain>.workers.dev/health
```

Confirm the AAAA record exists — this is the whole point:

```bash
python -c "import socket;print(socket.getaddrinfo('speedquiz-api.<your-subdomain>.workers.dev',443,socket.AF_INET6))"
```

Then test on the phone **with Wi-Fi off**.

## Point the app at it

Rebuild with the Worker URL as the API base:

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://speedquiz-api.<your-subdomain>.workers.dev --dart-define=GOOGLE_SERVER_CLIENT_ID=<your-web-client-id>
```

Also update `SHARE_PUBLIC_BASE_URL` on **both** Railway services to the Worker
URL and redeploy, or share links will point at an address IPv6-only users
cannot open.

## Limits and trade-offs

- **100,000 requests/day** on the free plan. A full quiz run is roughly 15
  requests, so about 6,500 runs/day. Past that it is $5/mo, or move to a custom
  domain proxied by Cloudflare.
- Adds one hop, but Cloudflare has edge presence in far more places than
  Railway does — for users far from your Railway region this is often *faster*
  than connecting directly.
- Railway stays the origin. Nothing about the deployment changes.

## Long term

When you buy a domain for the Play listing, put it on Cloudflare with the proxy
enabled and point it at Railway directly. That gives you IPv6, no request cap
and one less moving part. This Worker is the free stand-in until then.
