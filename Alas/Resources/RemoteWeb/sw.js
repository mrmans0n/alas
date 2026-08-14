const CACHE_NAME = "alas-remote-shell-v40";
const SHELL_ASSETS = [
  "/",
  "/index.html",
  "/style.css?v=40",
  "/session-ordering.js?v=1",
  "/app.js?v=62",
  "/marked.min.js?v=28",
  "/purify.min.js?v=28",
  "/manifest.webmanifest",
  "/icon.svg",
  "/icon-180.png",
  "/icon-192.png",
  "/icon-512.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(SHELL_ASSETS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);

  if (request.method !== "GET") return;
  if (
    url.pathname === "/pair" ||
    url.pathname === "/ws" ||
    url.pathname === "/health" ||
    url.pathname === "/remote-info" ||
    url.pathname.startsWith("/api/")
  ) return;
  if (request.headers.get("upgrade") === "websocket") return;

  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request).catch(() => caches.match("/index.html"))
    );
    return;
  }

  if (!SHELL_ASSETS.includes(url.pathname + url.search) && !SHELL_ASSETS.includes(url.pathname)) return;

  event.respondWith(
    caches.match(request).then((cached) => cached || fetch(request))
  );
});
