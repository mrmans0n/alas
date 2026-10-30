# Opening a host run's endpoint in the in-app web preview — design

## Intent

Locally, a run's Open endpoint action opens the dev server in the in-app web preview: a WebKit view with address bar, back and forward, a console error popover and capture. Since #2253 and #2254, a paired host run's loopback endpoint is forwarded to a Mac port, but it opens in the default browser, because the peer view had no place for a preview. This design brings it into the app, as locally.

The user asked for this phase to run unattended, so the calls below are mine.

## Current state (from recon, origin/main 43e0db9f0)

- **Local.**
  - `TabsManager.openWebPreview` keeps one preview tab per worktree. Its live state is a `WebPreviewBrowser`, cached by owner key: a non-persistent `WKWebView`, address, history, console errors and capture.
  - `WebPreviewNavigation.allows` and `allowsResolved` refuse loopback URLs whenever the owner is remote (`remoteHost != nil`), resolving DNS too, so a remote project's page can never reach the Mac's own services.
- **Peer.**
  - `NativePeerRunTabView.openEndpoint` gets the forwarded `http://127.0.0.1:<port>/…` from `hosts.forwardedEndpoint` and calls `NSWorkspace.open`.
  - Forwards stop when the run stops, the host goes offline or the app quits. Nothing tells the UI.
- **The Mac's peer center** shows one override at a time (review, commit editor, history, host file) over the document. Each is a `NativePeerSessions` property cleared on selection changes, with a close button.

## Goals

1. **Open in the app.** Opening a forwarded endpoint shows the in-app web preview in the host worktree's center, with local's toolbar, console and capture, and a close button.
2. **Only the forward is reachable.**
   - The preview may load the forwarded port on `127.0.0.1` or `localhost`, and nothing else on the Mac's loopback.
   - Any other loopback URL, such as another port, a redirect or a link, is refused exactly as a remote project's preview refuses loopback today.
   - Non-loopback URLs behave as in a remote project's preview.
3. **A stopped forward closes the preview.** When the run stops, the host disconnects or the forward ends, the preview closes and shows the previous center content. The page never lingers on a port that a later forward could reuse.
4. **Non-loopback endpoints** still open in the default browser, as today. Older hosts are unchanged.

## Non-goals

- `preview_*` automation of a host preview. It has no owner session on the Mac.
- Persisting the preview across relaunches. The forward's port doesn't survive one.
- More than one host preview at a time.

## Anti-goals

- **No change to local or SSH previews.** The new allowance defaults to off.
- **No widening of loopback access** beyond the single forwarded port.

## Constraints

- AGENTS.md:
  - Swift Testing, minimal sharp tests;
  - no UI imports in core;
  - Conventional Commits, no attribution.
- The app can't be built locally, so CI is its first build.

## Decisions (my calls)

- **A port pin in the navigation policy.**
  - `WebPreviewNavigation.allows` and `allowsResolved` take `allowedLoopbackPort: Int?`, default nil.
  - With it set and a remote owner, a loopback URL passes only when its port equals the pin. A URL whose host resolves to loopback passes only on that port.
  - `WebPreviewBrowser` carries the pin to every check, and the loopback error and the open-externally guard respect it.
  - The decision is a plain function and gets a parameterized test.
- **An `openedWebPreview` override on `NativePeerSessions`:** server id, run id and the forwarded URL. It is cleared wherever the other overrides are cleared, and when the forward for that run stops.
  - `NativePeerHosts` reports stopped forwards through a callback the sessions object installs.
- **The view reuses `WebPreviewTabView`'s content with its own `WebPreviewBrowser`.**
  - The browser is held by the override, keyed `peer:<serverId>:<runID>`, and closed when the override clears. It stays out of `TabsManager`'s local cache and is not persisted.
  - Whether to extract a host-agnostic content view from `WebPreviewTabView`, or to give it an init that takes a browser, is left to the builder. Prefer the smaller diff.
- **One PR,** Mac only.
