// GET /?url=<http(s) image URL>  →  the image, fetched by Cloudflare instead of the user's Mac.
//
// Only images come back (by Content-Type), at most MAX_BYTES, with every redirect hop checked again. Requests carry
// no cookies or client headers, and hosts that name a private, loopback or link-local address are refused.

const MAX_BYTES = 10 * 1024 * 1024;
const MAX_REDIRECTS = 3;
const CACHE_SECONDS = 86400;

export default {
  async fetch(request, env) {
    if (request.method !== "GET" && request.method !== "HEAD") return fail(405, "Method not allowed");
    if (env.PROXY_KEY && request.headers.get("X-Proxy-Key") !== env.PROXY_KEY) return fail(403, "Forbidden");

    let target;
    try {
      target = new URL(new URL(request.url).searchParams.get("url") ?? "");
    } catch {
      return fail(400, "Missing or invalid url");
    }

    for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
      const problem = refusal(target);
      if (problem) return fail(400, problem);

      let upstream;
      try {
        upstream = await fetch(target.toString(), {
          method: "GET",
          redirect: "manual",
          headers: { Accept: "image/*", "User-Agent": "OrbitBar-ImageProxy/1" },
          cf: { cacheEverything: true, cacheTtl: CACHE_SECONDS },
        });
      } catch {
        return fail(502, "Could not reach the image host");
      }

      if ([301, 302, 303, 307, 308].includes(upstream.status)) {
        const location = upstream.headers.get("Location");
        if (!location) return fail(502, "Redirect without a location");
        target = new URL(location, target);
        continue;
      }
      if (!upstream.ok) return fail(upstream.status === 404 ? 404 : 502, `Image host answered ${upstream.status}`);

      const type = (upstream.headers.get("Content-Type") ?? "").split(";")[0].trim().toLowerCase();
      if (!type.startsWith("image/")) return fail(415, "Not an image");
      const declared = Number(upstream.headers.get("Content-Length") ?? 0);
      if (declared > MAX_BYTES) return fail(413, "Image too large");

      const headers = new Headers({
        "Content-Type": type,
        "Cache-Control": `public, max-age=${CACHE_SECONDS}`,
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "default-src 'none'; sandbox",
      });
      if (declared) headers.set("Content-Length", String(declared));
      if (request.method === "HEAD") return new Response(null, { headers });
      return new Response(upstream.body.pipeThrough(limit(MAX_BYTES)), { headers });
    }
    return fail(508, "Too many redirects");
  },
};

/** Why this URL must not be fetched, or null. */
function refusal(url) {
  if (url.protocol !== "http:" && url.protocol !== "https:") return "Only http and https";
  if (url.username || url.password) return "Credentials in the URL";
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal")) {
    return "Local host";
  }
  if (isPrivateIPv4(host) || isPrivateIPv6(host)) return "Private address";
  return null;
}

function isPrivateIPv4(host) {
  const m = host.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224;
}

function isPrivateIPv6(host) {
  if (!host.includes(":")) return false;
  if (host === "::" || host === "::1") return true;
  if (/^f[cd]/.test(host) || /^fe[89ab]/.test(host)) return true; // unique local, link-local
  const mapped = host.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  return mapped ? isPrivateIPv4(mapped[1]) : false;
}

/** Errors the stream once more than `max` bytes went through (a missing or false Content-Length). */
function limit(max) {
  let seen = 0;
  return new TransformStream({
    transform(chunk, controller) {
      seen += chunk.byteLength;
      if (seen > max) controller.error(new Error("Image too large"));
      else controller.enqueue(chunk);
    },
  });
}

function fail(status, message) {
  return new Response(message, {
    status,
    headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" },
  });
}
