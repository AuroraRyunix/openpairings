// Manubrium's service worker (docs/manubrium.md). Served at /m/sw.js by
// PairingsEngineWeb.MobileAppController, which stamps the release into
// VERSION below - a new release is a new worker, and its first act is to
// throw away the old one's cache. Scope: /m/. Pages outside it never run
// through this file.
//
// What it keeps, and nothing else:
//   * the result-entry page, /m/results - network first; kept only when it
//     answered 200 without a redirect, dropped the moment it redirects (the
//     phone is no longer enrolled) or the phone leaves (/m/leave);
//   * the public /assets/ bundles that page loads (app.js, app.css). They are
//     the same for every visitor and carry no session.
// Every other request - another page, /m/sync, anything not a GET - goes to
// the network exactly as if there were no worker.
//
// Not testable from `mix test`; see docs/manubrium.md for what was checked
// by hand.

const VERSION = "__MANUBRIUM_VERSION__";
// The offline page's words, through gettext like every other string; the
// controller writes them in as a JSON object.
const TEXT = __MANUBRIUM_TEXT__;
const CACHE = `manubrium-${VERSION}`;
const PAGE = "/m/results";

self.addEventListener("install", () => self.skipWaiting());

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      for (const key of await caches.keys()) {
        if (key.startsWith("manubrium-") && key !== CACHE) await caches.delete(key);
      }
      await self.clients.claim();
    })()
  );
});

// The page asks for this when the phone leaves, so a page with somebody's
// boards on it does not outlive the enrolment on a shared phone.
self.addEventListener("message", (event) => {
  if (event.data === "manubrium:forget") event.waitUntil(caches.delete(CACHE));
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (request.mode === "navigate") {
    if (url.pathname === PAGE) event.respondWith(page(request));
    else if (url.pathname === "/m/leave") event.waitUntil(caches.delete(CACHE));
    return;
  }

  if (url.pathname.startsWith("/assets/")) event.respondWith(asset(request));
});

async function page(request) {
  const cache = await caches.open(CACHE);

  try {
    const response = await fetch(request);

    // A navigation's redirect comes back opaque (`ok` false): not enrolled
    // any more, so nothing of the old page should be left to show.
    if (response.ok && !response.redirected && response.type === "basic") {
      await cache.put(PAGE, response.clone());
    } else {
      await cache.delete(PAGE);
    }

    return response;
  } catch (_offline) {
    return (await cache.match(PAGE)) || offline();
  }
}

// Network first here too: in development the bundle names are not digested,
// and a cache-first worker would serve yesterday's JavaScript forever.
async function asset(request) {
  const cache = await caches.open(CACHE);

  try {
    const response = await fetch(request);
    if (response.ok && response.type === "basic") await cache.put(request, response.clone());
    return response;
  } catch (offlineError) {
    const cached = await cache.match(request);
    if (cached) return cached;
    throw offlineError;
  }
}

// Only reached when the phone has never opened the result page with a
// connection since this worker arrived - there is nothing to show yet.
function offline() {
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"})[c]);
  const html =
    '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">' +
    "<title>Manubrium</title>" +
    '<body style="font:17px/1.5 system-ui,sans-serif;margin:0;padding:32px 20px;background:#0e1210;color:#e8e6e1">' +
    `<h1 style="font-size:22px">${esc(TEXT.title)}</h1><p>${esc(TEXT.body)}</p>`;

  return new Response(html, {
    status: 503,
    headers: {"content-type": "text/html; charset=utf-8", "cache-control": "no-store"},
  });
}
