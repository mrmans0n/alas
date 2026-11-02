# Keep remote previews off this Mac's own services

Date: 2026-11-02
Status: implemented

## Intent

A remote-owned web preview, such as an SSH project's dev server or a paired
host's forwarded run, shows a page that this Mac does not control. That page
must not be able to reach services on this Mac: loopback, or a service bound
to all interfaces and reachable on the Mac's LAN or tailnet address. The only
exception is the one forwarded address the preview was opened for.

#2304 closed this for any URL whose text names loopback. This design closes the
rest of the gap: names that resolve to this Mac, and this Mac's own non-loopback
addresses, for every kind of request a page can make.

## Current state

- `WebPreviewLoopbackRules` (`Alas/Sources/WebPreview/WebPreviewBrowser.swift`)
  compiles a `WKContentRuleList` per pin. It blocks `localhost`, `*.localhost`,
  `127.0.0.0/8`, `0.0.0.0`, `[::]`, `[::1]` and IPv4-mapped loopback for all
  resource types. `WebPreviewLoopbackPin` exempts the forward's exact host and
  port.
- Navigations also go through `WebPreviewNavigation.allowsResolved`. It does a
  bounded `getaddrinfo` and refuses any loopback answer.
- Remote browsers load nothing until the rules are installed. That is the
  `loopbackRules` `.pending/.installed/.failed` gate, and `loadAwaitingRules`
  holds the deferred load.
- Gaps, as `docs/web-previews.md` says:
  1. Subresources (fetch, XHR, img, script, CSS, frames, WebSocket, workers) to
     a name that resolves to loopback, such as `127.0.0.1.nip.io`,
     `localtest.me`, a hosts-file alias, or DNS rebinding after the navigation
     check.
  2. Requests to this Mac's own LAN or tailnet addresses, by literal or by name.
     A dev server bound to `0.0.0.0` is reachable there.
  3. The navigation DNS check cannot pin WebKit's later connection, so
     rebinding beats it as well.

## Goals

- Every connection a remote preview opens is checked against the address it
  actually connects to, after resolution. This covers HTTP, HTTPS, WebSocket,
  redirects, workers, and service workers.
- Refused destinations: loopback, unspecified, link-local, this Mac's own
  interface addresses, and IPv4-mapped forms of all of these. The only
  exception is the pinned forward.
- Fail closed. If the protection cannot be set up, or stops working, the
  preview loads nothing. It never falls back to direct connections.
- Scope is per preview. Local-owned previews and other web views are untouched.
- No new entitlements, no system-wide components, and no private API.

## Non-goals

- A general network sandbox for remote pages. Remote-to-remote and
  remote-to-internet traffic stay allowed, including other hosts on the LAN.
  The remote host is usually on that LAN.
- Changing local-owned previews. Those may load `localhost` by design.
- Hiding which names a page looks up. WebKit's DNS prefetch can still query
  names; it opens no connection.

## Anti-goals

- Do not inject JavaScript that wraps `fetch` or `WebSocket`. Images, CSS,
  frames, and workers bypass it, so it is not a boundary.
- Do not use a Network Extension or `pf`. Both need entitlements or root,
  approval by the user, and they apply system-wide.
- Do not refuse private ranges in general (RFC 1918, CGNAT, ULA). That would
  break the normal case, where the remote host is on the LAN or tailnet.
- Do not re-resolve a name after vetting it. Connect to the exact address that
  was checked.

## Probes (macOS 27.0.1, Xcode Swift 6.4.2)

Scratch programs are in `/tmp/alas-proxy-probe`; they are not committed:

- `probe.swift`: an offscreen `WKWebView` on a `.nonPersistent()` store with
  `proxyConfigurations` set.
- `servers.py`: a target HTTP and WebSocket server on `127.0.0.1`, an HTTPS
  variant with a self-signed certificate, a logging HTTP CONNECT proxy, and a
  logging SOCKS5 proxy.

Both proxies map the made-up name `alas-probe.invalid` to `127.0.0.1`. A request
that reaches the target under that name therefore proves that WebKit handed the
unresolved name to the proxy, because the system resolver cannot resolve it.

| Question | Result |
|---|---|
| Does plain `http` go through an HTTP CONNECT proxy? | Yes, as `CONNECT host:port`. Requests were never sent in absolute form, so the proxy only has to handle CONNECT. |
| `https`? | Yes, through CONNECT. Server trust is still evaluated by WebKit's challenge delegate. |
| `ws` (WebSocket upgrade)? | Yes. Each socket opens its own CONNECT, and `ws open` arrived. `wss` uses the same path with TLS inside the tunnel; it was not tested separately. |
| Dedicated worker `fetch`? | Yes, the worker's fetch reached the target under the unresolvable name. |
| Service worker, registered over HTTPS, with a fetch from `install`? | Yes. It registered, and the install fetch reached the target through the proxy. Over plain `http` with a non-trustworthy origin, `navigator.serviceWorker` is undefined. |
| Redirect to another origin? | Every hop opens a new CONNECT. The proxy saw the post-redirect destination. |
| Who resolves DNS? | The proxy. CONNECT and SOCKS5 both carried the name (SOCKS5 used `ATYP=DOMAIN`). `127.0.0.1.nip.io`, `foo.localhost` and `x.local` all arrived unresolved. |
| Scope | Per `WKWebsiteDataStore`. A second web view in the same process, on its own `.nonPersistent()` store with no proxy, connected directly. |
| Set after the web view exists? | Yes. Setting `proxyConfigurations` 0.5 s after creating the web view, before the first load, was honoured. |
| `allowFailover` default | `false`. With the proxy port closed, the load failed with `NSURLErrorCannotConnectToHost` and nothing reached the target, so it fails closed. With `true` it silently connected directly. |
| Proxy credentials (`applyCredential`) | They were not sent preemptively, and CONNECT had no `Proxy-Authorization` header. They cannot identify a browser without a 407 round trip. |
| **Which destinations bypass the proxy?** | WebKit or Network.framework connects **directly**, with no CONNECT, to: IP-literal loopback (`127.0.0.1`, `127.0.0.2`, `[::1]`, `[::ffff:127.0.0.1]`, and `2130706433`, which canonicalizes to `127.0.0.1`), the name `localhost`, IPv4 link-local (`169.254.10.10`), and **this Mac's own interface addresses** (`192.168.1.143` on en0, `[::ffff:192.168.1.143]`, the tailnet IPv6 `fd7a:…:d614`). A listener on `[::]` received these directly, WebSocket included. `0.0.0.0` was not proxied either and did not reach the target; the rule list already blocks it. |
| Proxied literals | `10.0.0.1`, `172.16.0.1`, `192.168.1.1` (the gateway), `192.168.1.250` (same subnet, not this Mac), `8.8.8.8`, `[fe80::1]`, `[::]`, `[fd00::1]`, `[2001:db8::1]`, another tailnet address, and, oddly, this Mac's own tailnet IPv4 `100.113.214.20` on the point-to-point `utun`. `[::ffff:8.8.8.8]` arrived unmapped as `8.8.8.8`. |
| Can `matchDomains` force the bypassed literals through the proxy? | No. With `matchDomains = ["192.168.1.143", "127.0.0.1", …]`, both still went direct. Network.framework has no public knob for its local bypass. |
| `WKURLSchemeHandler` | `WKWebView.handlesURLScheme` is `true` for `http`, `https`, `ws` and `wss`. WebKit refuses a handler for built-in schemes, so this is ruled out. |

The bypass is the key finding. **A proxy alone does not cover a literal URL for
this Mac's own address.** It does cover every name, because names always reach
the proxy, including names that resolve to loopback or to this Mac. The
literals that bypass it are exactly the class a URL-text rule can match. The
two mechanisms therefore complement each other.

## Decision

Keep the content rule list for literals, and add a per-browser in-process HTTP
CONNECT proxy for everything else.

1. **Egress proxy (new, in `AlasCore`).** It runs only for remote browsers and
   is set as the browser's data store `proxyConfigurations` with
   `allowFailover = false`. For each `CONNECT host:port`, it resolves the host
   once, classifies every address, and refuses the connection unless every
   answer is allowed. This mirrors `allowsResolved`'s `allSatisfy`. Otherwise
   it connects to the first vetted address itself, replies
   `200 Connection Established`, and splices bytes. The vetted address is a
   numeric `NWEndpoint`, so nothing re-resolves it and rebinding has nothing to
   act on.
2. **Content rules, extended.** These cover the literals WebKit sends around
   the proxy. Add IPv4 link-local `169.254.0.0/16` and its IPv4-mapped form,
   plus a rule per current interface address of this Mac. For IPv4 that means
   the dotted form and the canonical mapped form, `[::ffff:c0a8:18f]`; for IPv6,
   the compressed lowercase form. The pin exemption is unchanged.
3. **Navigation DNS check stays** as the early, user-visible error for typed
   URLs. The proxy is the enforcement point.

### Components

**`WebPreviewEgressPolicy`** lives in `Packages/AlasCore/Sources/AlasFeatures/RunScripts/`,
next to `RunEndpointPolicy`. It is pure, and its input is the 4 or 16 address
bytes.

- It refuses the following:
  - IPv4 `127.0.0.0/8`, `0.0.0.0/8`, and `169.254.0.0/16`.
  - IPv6 `::1`, `::`, and `fe80::/10`.
  - IPv4-mapped `::ffff:a.b.c.d` and IPv4-compatible `::a.b.c.d`, classified by
    the embedded IPv4 address.
  - Any address in the injected `localAddresses` set. That set is compared as
    canonical bytes, so the IPv6 zone is dropped and mapped forms are unmapped.
    The app reads it with `getifaddrs` for every CONNECT, so no change can be
    missed between path updates.
  - Tailscale's service addresses `100.100.100.100` and `fd7a:115c:a1e0::53`,
    which terminate on this Mac.
- The proxy has no pin. WebKit sends the forward's loopback literal, and
  `localhost`, around the proxy, so the content rules' exemption and the
  navigation check are what let the forward through. (Implementation review
  dropped the pin the first version carried.)
- Parameterized tests cover the table above.

**`WebPreviewEgressProxy`** also lives in `AlasFeatures`. It uses Network.framework
only, which is allowed in core, and is modelled on `PeerPortForwarder`'s
`NWListener` handling.

- It has one `NWListener` per remote browser on `127.0.0.1`, with an ephemeral
  port. The port identifies the browser, so no credentials are needed; the
  probe showed `applyCredential` does not help anyway.
- It reads the request head with a cap (8 KiB, 5 s). Anything other than
  `CONNECT` gets `405`, and a malformed head gets `400`.
- Resolution is an injected `resolve` closure. Its default is a `getaddrinfo`
  lookup on a utility queue with a 5 s bound, moved from
  `WebPreviewHostLookup.lookupAddresses` so the app's navigation check shares
  it.
- Results: refused gets `403`, and the destination is reported through an
  `onBlocked(host, port, reason)` callback. A DNS failure or timeout gets
  `502`, and a connect failure gets `502`. WebKit turns any non-2xx response
  into a failed load for that request.
- A splice loop runs per tunnel and closes both ends when either ends.
  `stop()` cancels the listener and all tunnels.
- `localAddresses` is an injected `@Sendable () -> Set<Data>` that is read per
  CONNECT. It is cheap to read, and the snapshot is cached and refreshed when
  the network path changes. The app passes the result of
  `RemoteNetwork.interfaces()`, which already walks `getifaddrs` but lives in
  `AlasHostCore`; `AlasFeatures` cannot import that target.

**App wiring** (`WebPreviewBrowser`):

- `init`, when remote, starts the proxy. When the proxy is ready, it sets
  `webView.configuration.websiteDataStore.proxyConfigurations =
  [ProxyConfiguration(httpCONNECTProxy: 127.0.0.1:port)]` with
  `allowFailover = false`.
- The existing gate grows from "rules installed" to "rules installed and proxy
  ready". Both run concurrently, and `loadAwaitingRules` waits for both. If
  either fails, the browser enters the existing `.failed` state, which shows an
  error and retries on the next navigation. On retry, a dead proxy is restarted
  and the store is pointed at the new port; the probe showed late assignment
  works.
- `onBlocked` appends a bounded console entry, for example `Blocked request
  to 127.0.0.1.nip.io:5432: resolves to this Mac`. `preview_console` then shows
  agents why a fetch failed.
- `close()` stops the proxy.
- `WebPreviewLoopbackRules.json(allowing:selfAddresses:)` and the compiled
  identifier include a hash of the address set. A single shared
  `NWPathMonitor` recompiles the list when the set changes, and each remote
  browser swaps it in (`remove(old)`, then `add(new)`).

### Failure behaviour

| Condition | Result |
|---|---|
| Listener cannot start | Same as a rule-compile failure: nothing loads, an error is shown, and the next navigation retries. |
| Listener dies mid-session | With `allowFailover = false`, every new connection fails, so it fails closed. The next navigation restarts it. |
| DNS fails or times out | `502`. The request fails, and a navigation shows WebKit's error. |
| Any resolved address is refused | `403` and a console entry. |
| Rule recompile in flight after an address change | The new address is reachable by literal for the compile time, about tens of ms. By name it is already refused, because the proxy reads `localAddresses` per CONNECT. |

### Performance

- Each connection adds one loopback hop and one `getaddrinfo` call, which the
  system cache usually answers.
- Tunnels are long-lived: HTTP keep-alive and HTTP/2 multiplexing reuse one
  CONNECT. The cost is per connection, not per request.
- The splice is a userspace copy on loopback, which is negligible next to the
  remote network.
- The proxy was not benchmarked. The probe's Python proxy served every page
  without noticeable delay. Budget: no visible change in load time for a
  typical dev server page. Measure with the implementation.

### Tests

The test policy applies, so these are few and sharp.

- `AlasCoreTests`, extending an existing suite:
  - A parameterized `WebPreviewEgressPolicy` table covering IPv4, IPv6, mapped
    and compatible forms, the local set, and the pin.
  - One real proxy test. An `NWConnection` client sends `CONNECT` through the
    proxy to an injected resolver that maps `allowed.invalid` to this Mac's LAN
    address, where an echo server listens and which the injected
    `localAddresses` leaves out so it stands in for a remote host, and
    `blocked.invalid` to `127.0.0.1`. The test asserts `200` plus echoed bytes
    for the first, and `403` with no accept for the second. No external DNS,
    no WebKit. (With no proxy pin, a loopback destination can no longer play
    the allowed one.)
- `AlasTests`:
  - One WebKit integration test that pins the bypass assumption. A remote
    browser with an injected resolver loads a page from the proxy's pinned
    loopback origin. That page fetches `http://rebind.invalid:<port>/`, which
    resolves to `127.0.0.1`. Assert that the probe server never sees the
    request and that `consoleErrors` records the block.
  - This is the test that fails if WebKit ever stops honouring
    `proxyConfigurations`.
  - It needs the resolver to be injectable through `WebPreviewBrowser.init`.
    It already is for navigations, and the same closure reaches the proxy.
- The own-address literal rules are covered by extending the existing
  `WebPreviewLoopbackRules.json` test with an address set.

## What remains uncovered

- **WebRTC and other UDP traffic.** It does not use the proxy. Reaching a TCP
  service through it is not possible, and a UDP service would have to speak
  STUN/DTLS, so the risk is low. There is no public API to turn RTC off in
  `WKWebView`.
- **HTTP/3 (QUIC).** It cannot ride an HTTP CONNECT tunnel. Probed on macOS
  27.0.1 against `cloudflare-quic.com`, which advertises `h3`. The site's
  `/cdn-cgi/trace` reports the protocol the server saw. With a persistent
  store and no proxy, every load was `http/3`. With the proxy, the same store
  loaded over `http/2` through it, despite a cached `h3` `Alt-Svc` entry. With
  the proxy refusing every connection, every load failed with no QUIC
  fallback. A non-persistent store, which previews use, was `http/2` even
  without a proxy. So WebKit does not bypass the proxy over QUIC today.
- **The window after an address change.** A literal URL for a brand-new own
  address is reachable until the rule list is recompiled. Names are not
  affected.
- **WebKit's bypass list is undocumented.** The probe shows that own
  addresses bypass the proxy, but the tailnet IPv4 did not. Content rules
  block all own addresses regardless, so a change in either direction stays
  covered. The WebKit integration test catches the case where `proxyConfigurations`
  stops applying at all.
- **Other processes on this Mac can use a running remote preview's proxy.**
  Web pages cannot: browsers forbid `CONNECT` from `fetch` and XHR. A local
  process can, and the proxy then reaches LAN hosts as Alas, under Alas's
  Local Network permission rather than its own. It still cannot reach this
  Mac's own services. This is an accepted risk: any local process running as
  the user can already drive Alas in other ways.
- **Limits.** A proxy holds at most 128 tunnels, answering `503` beyond, and
  resolves at most 4 names at once, with further CONNECTs waiting in order.
  Lookups share an app-wide pool of 16, so one page cannot starve other
  previews or the navigation check. A connect that fails moves on to the
  name's next vetted address.
- **DNS prefetch.** WebKit may still query names; it opens no connections.

## Risks

- **Local Network privacy.** The app process now makes the LAN connections
  instead of WebKit's networking process. The app already declares
  `NSLocalNetworkUsageDescription` for pairing, and both are attributed to
  Alas. Check that a first-run user who denied the prompt sees a clear error
  rather than a hang.
- **macOS minimum.** `proxyConfigurations` is macOS 14+. Alas targets 15, so
  there is no fallback path.
- **Behaviour change.** A remote preview whose URL is this Mac's own LAN or
  tailnet address is blocked after this change. Today it is allowed. Someone
  doing an SSH session to their own Mac would notice.

## Effort

- Core policy and proxy: about 250 lines plus about 120 lines of tests.
- App wiring, rule extension, and path monitor: about 120 lines plus one
  WebKit test.
- Doc update in `docs/web-previews.md`.
- About 2 to 3 days including the HTTP/3 and Local Network checks.

## Open questions for the user

1. **IPv4 and IPv6 link-local (`169.254/16`, `fe80::/10`).** These are not this
   Mac, but the brief lists them as refused. A remote host on a direct cable
   link would become unreachable. Refuse them (the default here), or allow
   them?
2. **Should own-address refusal also apply to the navigation check**, so a
   typed `http://<this Mac's LAN IP>:3000` gets the early, explained error
   instead of a WebKit load failure?
3. **Is a blocked-request line in `preview_console` wanted?** It is useful for
   agents, but it reveals that the destination resolves to this Mac.
4. **Should HTTP/3 be disabled for remote previews** if the probe shows it
   bypasses the proxy? That would need private API, which is off the table, so
   the alternative is to accept and document it. Resolved: the probe showed no bypass.
