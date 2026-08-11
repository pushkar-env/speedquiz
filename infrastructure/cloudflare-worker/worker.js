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

    try {
      const response = await fetch(proxied);

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
