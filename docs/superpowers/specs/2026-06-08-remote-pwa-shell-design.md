# Remote PWA Shell Design

## Goal

Make the existing Alas Remote web client more app-like and resilient when opened from a paired device while the Mac-hosted remote server is unavailable.

The first pass focuses on the app shell only. It should be possible, where the browser and origin allow service workers, to reopen the remote client and see a clear "Alas is unreachable" state with a manual retry action. This change does not add cached transcripts, offline session browsing, queued prompts, or offline permission decisions.

## Current Context

The remote client is a static single-page web app in `Alas/Resources/RemoteWeb`. `AppState` serves that directory through `RemoteServer`, which exposes:

- `GET /` and static files from the app bundle.
- `POST /pair` for pairing-code redemption.
- `GET /ws` upgraded to WebSocket for live session state and control.

The settings pane currently advertises an address like `http://<LAN-or-tailnet-IP>:<port>`. Plain HTTP on a LAN IP is enough for the live web app, but it limits installability and service worker availability on many browsers. `localhost` is treated specially by browsers, but a phone opening the Mac's LAN IP is not a same-device localhost case.

## Approach

Add a lightweight PWA layer around the existing static client:

- Add a web app manifest with app identity, scope, standalone display, theme/background colors, and icons.
- Add a service worker that precaches only static shell assets.
- Register the service worker from the app page when `navigator.serviceWorker` is available.
- Add Apple home-screen metadata so Safari has useful title/icon/status styling even when full PWA behavior is limited.
- Improve the disconnected state so reopening the shell without a reachable server shows an explicit unreachable gate and a "Try again" button.

The service worker must not cache or synthesize responses for `/pair`, `/ws`, or future control endpoints. Those routes remain network-only because they are authentication and live-control paths.

## App Shell Behavior

On startup, the client continues to call `ensureToken()`:

- If a `?code=` query parameter is present, it attempts pairing through `POST /pair`.
- If a stored token exists, it proceeds to connect the WebSocket.
- If neither exists, it shows the existing pairing instructions.

When pairing or the WebSocket cannot reach the Mac:

- Show a full-screen gate titled "Can't reach Alas".
- Explain that the Mac must be awake, Alas must be running, and the device must be on the same LAN or tailnet.
- Show a "Try again" button.
- Pressing retry clears the current reconnect timer state, resets the backoff delay, updates the status chip to "Connecting...", and immediately calls `connect()`.

Automatic reconnect remains in place with capped exponential backoff. The manual retry is an additional user-controlled path, not a replacement.

## Service Worker

The service worker uses a versioned static cache for:

- `/`
- `/index.html`
- `/style.css`
- `/app.js`
- `/marked.min.js`
- `/purify.min.js`
- Manifest and icon assets.

Fetch handling:

- HTML/navigation and listed static files may be served from cache when the network is unavailable.
- `/pair`, `/ws`, and non-GET requests are passed through to the network.
- Cache activation removes old shell cache versions.

This keeps the cached surface small and avoids persisting sensitive live session/control responses.

## Server Changes

Extend static content type handling for the new files:

- `.webmanifest` -> `application/manifest+json; charset=utf-8`
- `.png` -> `image/png`
- `.svg` -> `image/svg+xml; charset=utf-8` if SVG icons are used.

No WebSocket or pairing protocol changes are required.

## Limitations

The PWA shell cannot guarantee offline opening from a phone until the remote app is served from a secure context accepted by that browser. With the current LAN HTTP address, this may work inconsistently or not at all depending on browser and platform.

This design intentionally does not cache session lists, transcripts, prompt drafts, or permission requests. When disconnected, all session-control actions stay unavailable.

## Testing

Add focused Swift tests for server asset behavior where practical:

- Manifest, service worker, and icons resolve from `RemoteWebAssets`.
- New file extensions return the expected content types.

Manual verification:

- Enable remote control and pair a browser.
- Confirm the page links the manifest and registers the service worker when supported.
- Stop Alas or disable remote control.
- Reopen the remote app and verify the unreachable gate appears with a working "Try again" button.
- Re-enable the server and confirm retry reconnects and refreshes the session list.
