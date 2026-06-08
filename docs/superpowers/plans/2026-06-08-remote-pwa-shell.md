# Remote PWA Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add lightweight PWA app-shell support for Alas Remote and show a clear unreachable state with a manual retry button when the Mac server cannot be reached.

**Architecture:** Keep the remote app as the existing static SPA served by `RemoteServer`. Add manifest/service-worker/icon static assets, teach the local HTTP responder the new content types, and update the client-side connection flow so cached shell startup fails into an explicit retry gate without caching authentication or live-control routes.

**Tech Stack:** Swift 5.9, Swift Testing, SwiftUI/macOS app bundle resources, plain HTML/CSS/JavaScript, service worker Cache API.

---

## File Structure

- Modify `Alas/Sources/Remote/Server/RemoteHTTPResponder.swift`
  - Responsibility: static asset lookup and HTTP content type mapping.
- Modify `AlasTests/Remote/RemoteServerIntegrationTests.swift`
  - Responsibility: integration coverage for static remote asset serving.
- Modify `Alas/Resources/RemoteWeb/index.html`
  - Responsibility: PWA metadata links and service-worker bootstrap.
- Modify `Alas/Resources/RemoteWeb/app.js`
  - Responsibility: connection state, unreachable gate, retry behavior.
- Modify `Alas/Resources/RemoteWeb/style.css`
  - Responsibility: visual styling for the retry gate button.
- Create `Alas/Resources/RemoteWeb/manifest.webmanifest`
  - Responsibility: PWA identity and install metadata.
- Create `Alas/Resources/RemoteWeb/sw.js`
  - Responsibility: static app-shell cache only.
- Create `Alas/Resources/RemoteWeb/icon.svg`
  - Responsibility: reusable app icon for manifest and Apple metadata.

## Task 1: Server Content Types and Asset Tests

**Files:**
- Modify: `Alas/Sources/Remote/Server/RemoteHTTPResponder.swift`
- Modify: `AlasTests/Remote/RemoteServerIntegrationTests.swift`

- [ ] **Step 1: Write failing tests for new content types**

Append these tests to `RemoteServerIntegrationTests` before the closing `}`:

```swift
    @Test func remoteWebAssetsServePWAContentTypes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-web-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(#"{"name":"Alas Remote"}"#.utf8)
            .write(to: root.appendingPathComponent("manifest.webmanifest"))
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
            .write(to: root.appendingPathComponent("icon.svg"))
        try Data([0x89, 0x50, 0x4E, 0x47])
            .write(to: root.appendingPathComponent("icon.png"))

        let assets = RemoteWebAssets(root: root)

        #expect(assets.asset(forPath: "/manifest.webmanifest")?.contentType == "application/manifest+json; charset=utf-8")
        #expect(assets.asset(forPath: "/icon.svg")?.contentType == "image/svg+xml; charset=utf-8")
        #expect(assets.asset(forPath: "/icon.png")?.contentType == "image/png")
    }

    @Test func remoteServerServesManifestWithManifestContentType() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-web-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(#"{"name":"Alas Remote"}"#.utf8)
            .write(to: root.appendingPathComponent("manifest.webmanifest"))

        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let assets = RemoteWebAssets(root: root)
        let server = RemoteServer(pairing: pairing, assets: assets, provider: FakeSessionsProvider())
        try server.start(port: 0)
        defer { server.stop() }

        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let port = try #require(server.port)

        let (data, resp) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/manifest.webmanifest")!
        )
        let http = try #require(resp as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "application/manifest+json; charset=utf-8")
        #expect(String(data: data, encoding: .utf8) == #"{"name":"Alas Remote"}"#)
    }
```

- [ ] **Step 2: Run tests and confirm failure**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteServerIntegrationTests test
```

Expected: the new tests fail because `.webmanifest`, `.svg`, and `.png` currently return `application/octet-stream`.

- [ ] **Step 3: Add content type mappings**

In `RemoteWebAssets.contentType(for:)`, replace the switch with:

```swift
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "webmanifest": return "application/manifest+json; charset=utf-8"
        case "svg": return "image/svg+xml; charset=utf-8"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
```

- [ ] **Step 4: Run focused tests and confirm pass**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteServerIntegrationTests test
```

Expected: `RemoteServerIntegrationTests` pass.

- [ ] **Step 5: Commit**

Run:

```bash
git add Alas/Sources/Remote/Server/RemoteHTTPResponder.swift AlasTests/Remote/RemoteServerIntegrationTests.swift
git commit -m "Add remote PWA asset content types"
```

## Task 2: PWA Manifest, Icon, and Service Worker

**Files:**
- Create: `Alas/Resources/RemoteWeb/manifest.webmanifest`
- Create: `Alas/Resources/RemoteWeb/sw.js`
- Create: `Alas/Resources/RemoteWeb/icon.svg`
- Modify: `Alas/Resources/RemoteWeb/index.html`

- [ ] **Step 1: Add manifest**

Create `Alas/Resources/RemoteWeb/manifest.webmanifest`:

```json
{
  "name": "Alas Remote",
  "short_name": "Alas",
  "description": "Remote session control for Alas.",
  "start_url": "/",
  "scope": "/",
  "display": "standalone",
  "background_color": "#101417",
  "theme_color": "#151c20",
  "icons": [
    {
      "src": "/icon.svg",
      "sizes": "any",
      "type": "image/svg+xml",
      "purpose": "any maskable"
    }
  ]
}
```

- [ ] **Step 2: Add icon**

Create `Alas/Resources/RemoteWeb/icon.svg`:

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect width="512" height="512" rx="96" fill="#151c20"/>
  <path d="M144 340 240 112h72l96 228h-64l-18-48H226l-18 48h-64Zm96-96h72l-36-96-36 96Z" fill="#7fd4df"/>
  <path d="M152 388h256" stroke="#dbe7ea" stroke-width="28" stroke-linecap="round"/>
</svg>
```

- [ ] **Step 3: Add service worker**

Create `Alas/Resources/RemoteWeb/sw.js`:

```javascript
const CACHE_NAME = "alas-remote-shell-v1";
const SHELL_ASSETS = [
  "/",
  "/index.html",
  "/style.css?v=26",
  "/app.js?v=26",
  "/marked.min.js?v=26",
  "/purify.min.js?v=26",
  "/manifest.webmanifest",
  "/icon.svg"
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
  if (url.pathname === "/pair" || url.pathname === "/ws") return;
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
```

- [ ] **Step 4: Link PWA metadata in HTML**

In `Alas/Resources/RemoteWeb/index.html`, add these lines in `<head>` after the viewport meta:

```html
  <meta name="theme-color" content="#151c20" />
  <meta name="apple-mobile-web-app-capable" content="yes" />
  <meta name="apple-mobile-web-app-title" content="Alas Remote" />
  <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />
  <link rel="manifest" href="/manifest.webmanifest" />
  <link rel="icon" href="/icon.svg" type="image/svg+xml" />
  <link rel="apple-touch-icon" href="/icon.svg" />
```

- [ ] **Step 5: Register service worker**

In `index.html`, add this inline script after the existing `/app.js?v=26` script:

```html
  <script>
    if ("serviceWorker" in navigator) {
      window.addEventListener("load", () => {
        navigator.serviceWorker.register("/sw.js").catch(() => {});
      });
    }
  </script>
```

- [ ] **Step 6: Verify static files are present**

Run:

```bash
test -f Alas/Resources/RemoteWeb/manifest.webmanifest
test -f Alas/Resources/RemoteWeb/sw.js
test -f Alas/Resources/RemoteWeb/icon.svg
```

Expected: all commands exit with status 0.

- [ ] **Step 7: Commit**

Run:

```bash
git add Alas/Resources/RemoteWeb/index.html Alas/Resources/RemoteWeb/manifest.webmanifest Alas/Resources/RemoteWeb/sw.js Alas/Resources/RemoteWeb/icon.svg
git commit -m "Add remote PWA shell assets"
```

## Task 3: Unreachable Gate and Manual Retry

**Files:**
- Modify: `Alas/Resources/RemoteWeb/app.js`
- Modify: `Alas/Resources/RemoteWeb/style.css`

- [ ] **Step 1: Add reconnect timer state**

Near the existing reconnect variables in `app.js`, change:

```javascript
let reconnectDelay = 1500;
const maxReconnectDelay = 30000;
```

to:

```javascript
let reconnectDelay = 1500;
let reconnectTimer = null;
const initialReconnectDelay = 1500;
const maxReconnectDelay = 30000;
```

- [ ] **Step 2: Add unreachable and retry helpers**

After `hideGate()`, add:

```javascript
function showUnreachableGate() {
  showGate("Can't reach Alas", "Make sure your Mac is awake, Alas is running, and this device is on the same Wi-Fi or tailnet.", true);
}

function scheduleReconnect() {
  if (reconnectTimer) clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, maxReconnectDelay);
}

function retryConnection() {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  reconnectDelay = initialReconnectDelay;
  setStatus("Connecting...", "connecting");
  connect();
}
```

- [ ] **Step 3: Use unreachable gate for pairing network failure**

In `ensureToken()`, replace the `catch` block around `fetch("/pair", ...)` with:

```javascript
    } catch (_) {
      showUnreachableGate();
      throw new Error("net");
    }
```

- [ ] **Step 4: Use manual retry and clearer gate on WebSocket close**

In `connect()`, replace the `ws.onopen` body with:

```javascript
  ws.onopen = () => {
    setStatus("Connected", "ok");
    hideGate();
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    reconnectDelay = initialReconnectDelay;
    send({ type: "listSessions" });
    if (currentSession) send({ type: "subscribe", sessionId: currentSession });
  };
```

Replace the `ws.onclose` body with:

```javascript
  ws.onclose = () => {
    setStatus("Reconnecting...", "bad");
    showUnreachableGate();
    scheduleReconnect();
  };
```

- [ ] **Step 5: Wire the retry button**

Near the bottom of `app.js`, find the existing event wiring area. Add:

```javascript
$("gate-retry").onclick = retryConnection;
```

If there is no grouped wiring section, add it near the other top-level `onclick` assignments so the handler is registered during initial script evaluation.

- [ ] **Step 6: Style retry as a clear action**

In `style.css`, replace the existing `#gate-retry` rule with:

```css
#gate-retry { margin-top: 18px; padding: 11px 20px; border: 0.5px solid color-mix(in oklab, var(--accent) 55%, transparent); border-radius: 10px; background: color-mix(in oklab, var(--accent) 18%, transparent); color: var(--fg); font-size: 15px; font-weight: 600; cursor: pointer; -webkit-tap-highlight-color: transparent; }
#gate-retry:active { background: color-mix(in oklab, var(--accent) 26%, transparent); }
```

- [ ] **Step 7: Sanity-check JavaScript syntax**

Run:

```bash
node --check Alas/Resources/RemoteWeb/app.js
node --check Alas/Resources/RemoteWeb/sw.js
```

Expected: both commands complete with no output.

- [ ] **Step 8: Commit**

Run:

```bash
git add Alas/Resources/RemoteWeb/app.js Alas/Resources/RemoteWeb/style.css
git commit -m "Show remote unreachable retry gate"
```

## Final Verification

- [ ] **Step 1: Confirm project generation is unchanged**

No `project.yml` changes are planned, so do not run `xcodegen` during this implementation. Confirm that `project.yml` is unchanged:

```bash
git diff --quiet -- project.yml
```

Expected: exit status 0.

- [ ] **Step 2: Run focused JavaScript checks**

Run:

```bash
node --check Alas/Resources/RemoteWeb/app.js
node --check Alas/Resources/RemoteWeb/sw.js
```

Expected: no output and exit status 0.

- [ ] **Step 3: Run focused remote tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteServerIntegrationTests test
```

Expected: `RemoteServerIntegrationTests` pass.

- [ ] **Step 4: Run required build**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: build succeeds.

- [ ] **Step 5: Run required full test suite**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: test suite succeeds.
