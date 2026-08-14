/**
 * IPv6 front door for the SpeedQuiz API.
 *
 * Railway's generated `*.up.railway.app` domains publish an A record but no
 * AAAA. Phones on IPv6-only mobile networks (Jio and most modern carriers)
 * therefore cannot reach the API at all — it works on dual-stack Wi-Fi and
 * fails on mobile data, which is a silent uninstall for real users.
 *
 * `*.workers.dev` publishes both A and AAAA, so this Worker accepts the
 * IPv6 connection and forwards it to Railway over IPv4. It is a transparent
 * pass-through: same paths, methods, headers, status codes and bodies.
 *
 * Deploy: see infrastructure/cloudflare-worker/README.md
 */

// The Railway service this proxies to. Override per-environment with a
// Worker variable named ORIGIN_HOST rather than editing this file.
const DEFAULT_ORIGIN = 'api-production-352e8.up.railway.app';

export default {
  async fetch(request, env) {
    const originHost = env.ORIGIN_HOST || DEFAULT_ORIGIN;

    const url = new URL(request.url);
    url.protocol = 'https:';
    url.hostname = originHost;
    url.port = '';

    // Passing `request` as init preserves method, headers, and body. The Host
    // header is derived from the new URL by the runtime, so the origin sees a
    // normal request for itself.
    const proxied = new Request(url.toString(), request);

    // uvicorn runs with --proxy-headers, so it trusts X-Forwarded-*. Cloudflare
    // sets these already; this just makes the client IP explicit for logging
    // and any future per-IP rate limiting.
    proxied.headers.set(
      'X-Forwarded-For',
      request.headers.get('CF-Connecting-IP') || '',
    );
    proxied.headers.set('X-Forwarded-Proto', 'https');

    // Re-assert the upgrade headers on the outbound request. Reconstructing a
    // Request is documented to preserve headers, but the runtime treats
    // `Upgrade` as a connection-level header and has been observed to drop it
    // across the copy — and when it does, the origin answers the handshake with
    // an ordinary 200 and every live match silently falls back to polling. It
    // costs nothing to set it explicitly, and the failure it prevents is
    // invisible from this side.
    const upgrade = request.headers.get('Upgrade');
    const isWebSocket = (upgrade || '').toLowerCase() === 'websocket';
    if (isWebSocket) {
      proxied.headers.set('Upgrade', upgrade);
      proxied.headers.set(
        'Connection',
        request.headers.get('Connection') || 'Upgrade',
      );
    }

    try {
      const response = await fetch(proxied);

      // A WebSocket upgrade must be returned *as-is*. Rewrapping it in
      // `new Response(body, init)` silently discards the `webSocket` handle,
      // and the client sees a 101 with no socket behind it — which is how a
      // live match would fail through this proxy while working perfectly
      // against the origin. Nothing below is worth breaking that for.
      //
      // Keyed on the status alone, not on `response.webSocket` being present:
      // a 101 that fell through to the rewrap below throws on a body that
      // cannot be read, turning a proxy quirk into a 502 that looks like the
      // origin is down.
      if (response.status === 101) {
        return response;
      }

      // Make the hop visible in curl -I, so a future debugging session can
      // tell "the proxy is down" from "the origin is down".
      const out = new Response(response.body, response);
      out.headers.set('X-Proxied-By', 'speedquiz-worker');
      return out;
    } catch (err) {
      // Distinguish a proxy failure from an origin 5xx.
      return new Response(
        JSON.stringify({
          detail: 'Upstream API unreachable via proxy.',
          origin: originHost,
          error: String(err),
        }),
        {
          status: 502,
          headers: { 'Content-Type': 'application/json' },
        },
      );
    }
  },
};
