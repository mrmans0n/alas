const CACHE_NAME = "alas-remote-shell-v122";
const SHELL_ASSETS = [
  "/",
  "/index.html",
  "/style.css?v=74",
  "/repo-filter.js?v=4",
  "/session-ordering.js?v=4",
  "/worktree-creation.js?v=2",
  "/changes-view.js?v=11",
  "/file-browser.js?v=3",
  "/peer-icons.js?v=1",
  "/hub-registry.js?v=4",
  "/hub-links.js?v=2",
  "/visual-aid.js?v=8",
  "/transcript-markdown.js?v=2",
  "/turn-changes.js?v=1",
  "/peer-console.js?v=1",
  "/terminals.js?v=8",
  // terminals.js loads these on first use; cached so a cached shell can still open a reachable host's terminals.
  "/xterm.min.js?v=1",
  "/xterm-addon-fit.min.js?v=1",
  "/xterm.css?v=1",
  "/app.js?v=130",
  "/marked.min.js?v=28",
  "/purify.min.js?v=28",
  "/manifest.webmanifest",
  "/icon.svg",
  "/icon-180.png",
  "/icon-192.png",
  "/icon-512.png",
  "/agent-icons/agent-claude.png",
  "/agent-icons/agent-codex.svg",
  "/agent-icons/agent-cursor.png",
  "/agent-icons/agent-pi.png",
  "/agent-icons/agent-omp.svg",
  "/agent-icons/agent-opencode.png",
  "/agent-icons/agent-gemini.png",
  "/agent-icons/agent-antigravity.svg",
  "/agent-icons/agent-copilot.png",
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

  // Cross-origin requests (pairing, health probes, sockets to OTHER Macs
  // from a hub served by this one) are never intercepted or cached.
  if (url.origin !== self.location.origin) return;

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

  // The diff bundle loads on demand: diffs.js and the grammars and themes it imports. Each is
  // cached the first time it loads, so a cached shell keeps showing diffs it already could.
  if (url.pathname.startsWith("/diffs/")) {
    event.respondWith(
      caches.open(CACHE_NAME).then((cache) => cache.match(request).then((cached) => cached || fetch(request).then((response) => {
        if (response.ok) cache.put(request, response.clone());
        return response;
      })))
    );
    return;
  }

  if (!SHELL_ASSETS.includes(url.pathname + url.search) && !SHELL_ASSETS.includes(url.pathname)) return;

  event.respondWith(
    caches.match(request).then((cached) => cached || fetch(request))
  );
});
