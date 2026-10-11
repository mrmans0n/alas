# Remote: Tailscale Serve Integration

## Goal

Make Alas Remote first-class on a tailnet: trust the MagicDNS name
automatically, offer an HTTPS address via `tailscale serve` (secure context →
PWA install, offline shell, notifications), and optionally stop listening on
the LAN. UI agreed: a separate **Tailscale** settings group (option B).

## Non-goals

- Funnel. Never public exposure; refuse to run when the target port is funneled.
- Tailscale identity headers for pairing auto-approval. Revisit only after
  "Tailscale only" ships, since headers are forgeable by anything that reaches
  the listener directly.
- LocalAPI socket client. The `tailscale` CLI is enough.

## Facts (checked on this Mac, Tailscale 1.102.4)

- CLI at `/usr/local/bin/tailscale`; App Store / standalone builds also ship
  `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.
- `tailscale status --json` → `BackendState` ("Running"), `Self.DNSName`
  (`macbook-air-de-nacho.tail85c3ae.ts.net.`, trailing dot), `CertDomains`
  (non-empty ⇔ HTTPS certs enabled for the tailnet).
- `tailscale serve status --json` → `{}` when nothing is served.
- Serve strips client-supplied `Tailscale-User-*` headers; Funnel requests
  carry none.

## Task 0 — spike (done 2026-10-11)

`tailscale serve --bg --https=443 http://127.0.0.1:<port>` in front of a
header-echo server, then in front of the running Alas:

1. Host is preserved: backend sees `Host: <name>.ts.net`, plus
   `X-Forwarded-Host`, `X-Forwarded-Proto: https`, `X-Forwarded-For: <tailnet IP>`.
   Peer address is `127.0.0.1`.
2. A client-sent `Tailscale-User-Login: evil@x` was replaced with the real
   login (`mrmans0n@github`).
3. `/ws` upgrade passes through (101).
4. Alas today answers **403 forbidden** through Serve (Host not allowlisted)
   and 200 on localhost — Task 2's MagicDNS auto-trust is required.
5. `tailscale serve --https=443 off` restores `{}`.

`serve status --json` with our handler (Task 1 fixture):

```json
{"TCP":{"443":{"HTTPS":true}},
 "Web":{"macbook-air-de-nacho.tail85c3ae.ts.net:443":
   {"Handlers":{"/":{"Proxy":"http://127.0.0.1:18765"}}}}}
```

Funnel adds `"AllowFunnel":{"<name>:443":true}` (from Tailscale's
`ipn.ServeConfig`; not exercised — enabling Funnel would publish the Mac).

## Task 1 — `RemoteTailscale` (new, `Alas/Sources/Remote/Settings/RemoteTailscale.swift`)

Small type, CLI-backed, pure parsing split from process I/O.

```swift
struct RemoteTailscaleStatus: Equatable, Sendable {
    let dnsName: String          // trailing dot stripped, lowercased
    let httpsEnabled: Bool       // CertDomains contains dnsName
}

enum RemoteTailscaleServeState: Equatable, Sendable {
    case off
    case ours                    // https:443 "/" → http://127.0.0.1:<port>
    case conflict(String)        // 443 "/" proxies something else, or funneled
}

enum RemoteTailscale {
    static func executable(fileManager:) -> String?              // PATH-known candidates
    static func parseStatus(_ json: Data) -> RemoteTailscaleStatus?   // nil unless Running
    static func parseServe(_ json: Data, dnsName: String, port: UInt16) -> RemoteTailscaleServeState
    static func status() async -> RemoteTailscaleStatus?         // Process.run, short timeout
    static func serveState(dnsName:port:) async -> RemoteTailscaleServeState
    static func enableServe(port:) async throws                  // tailscale serve --bg --https=443 http://127.0.0.1:<port>
    static func disableServe() async throws                      // tailscale serve --https=443 off
}
```

- Reuse `Process.run` (`Process+Git.swift`); timeout ~5 s.
- Never touch a handler that isn't ours: `enableServe` is only called when
  state is `.off` or `.ours`; `disableServe` only when `.ours`.
- `.conflict` when `AllowFunnel` is set for `<dnsName>:443`.

Tests (new `AlasTests/Remote/RemoteTailscaleTests.swift`, run `xcodegen`):
- `parseStatus`: running / stopped / missing DNSName / trailing-dot strip /
  httpsEnabled from CertDomains — one parameterized test.
- `parseServe`: empty → off; our proxy → ours; other port or other target →
  conflict; funneled → conflict — one parameterized test, Task 0 fixtures.

## Task 2 — config + network plumbing

`AppConfig.Remote` (keep Codable defaults backward-compatible, extend
`RemoteConfigTests` decode test only if it already covers missing keys):

```swift
var tailscaleServe: Bool = false
var tailscaleOnly: Bool = false
```

`RemoteAdvertisedAddress`: add an `init(kind:interfaceName:host:port:scheme:isRecommended:)`
path where `scheme == "https"` produces `url = "https://<host>"` (default port
omitted) and `id = "tailnet-https:<host>"`. Existing init unchanged.

`RemoteNetwork.advertisedAddresses` / `allowedHostCandidates`: take an
optional `tailscale: RemoteTailscaleStatus?` and `serveActive: Bool`:
- MagicDNS name (and its short label) always added to allowed hosts when
  status is non-nil — no toggle.
- When `serveActive`, prepend a `.tailnet` https address (recommended unless
  the user chose a preferred host).
- When `tailscaleOnly`, advertise only the https address (+ localhost).

Tests: extend `RemoteNetworkTests` — MagicDNS trusted; https address first
and well-formed; tailscaleOnly filters LAN/IP addresses. Kind stays `.tailnet`
so `RemotePairingLink` `kinds=` and `hub-links.js:442` treat it as
authoritative with no JS change.

## Task 3 — server bind

`RemoteServer.start(port:loopbackOnly:)`: when `loopbackOnly`, set
`params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: …)`.
Covered by one `RemoteServerIntegrationTests` case only if cheap (connect via
a non-loopback interface address fails); otherwise build-only.

`RemoteDiagnosticsSnapshot.usesPlainHTTP` → false when serve is active.

## Task 4 — AppState orchestration

`AppState`:
- `@Observable var remoteTailscale: RemoteTailscaleStatus?`,
  `remoteTailscaleServe: RemoteTailscaleServeState`, `remoteTailscaleError: String?`.
- `syncRemoteTailscale()` (async, called from `syncRemoteServer` after the
  port is known and from `onPortChange`):
  1. `status()`; nil → clear state, return.
  2. `serveState(port: remotePort)`.
  3. Want serve (`enabled && tailscaleServe && httpsEnabled`) and state is
     `.off` or stale `.ours` → `enableServe`. Don't want and `.ours` →
     `disableServe`. `.conflict` → surface message, do nothing.
  4. `refreshRemoteAccessState()`.
- `tailscaleOnly` change restarts the server (rebinding is required).
- Disabling remote control turns our serve handler off.
- `tailscaleOnly` forces Bonjour advertisement off (LAN peers can't reach a
  loopback listener); greyed in UI with a note.

## Task 5 — `RemoteServerPane` Tailscale group (option B)

New `SettingsGroup(title: "Tailscale")`, shown only when
`state.config.remote.enabled && state.remoteTailscale != nil`:

| Row | Content |
|---|---|
| Status | "Connected" badge · `<dnsName>` · "HTTPS certificates enabled" / "Enable HTTPS in the Tailscale admin console" |
| Serve over HTTPS | Toggle → `config.remote.tailscaleServe`; disabled without HTTPS certs; desc mentions PWA install + pinned port; conflict text in `.warn` |
| Tailscale only | Toggle → `config.remote.tailscaleOnly`; disabled unless serve is `.ours` |

The "Tailnet HTTPS" address row appears in the existing address list via
`remoteAdvertisedAddresses` (label from `addressLabel`: `.tailnet` +
https → "Tailnet HTTPS"). Update the "PWA install" info row to point at the
toggle when Tailscale is present.

## Verification

- `xcodebuild … -only-testing AlasTests/RemoteTailscaleTests -only-testing AlasTests/RemoteNetworkTests test`
  (+ `RemoteServerIntegrationTests` if Task 3 adds a case).
- Manual: toggle serve on → `tailscale serve status` shows our handler; phone
  on tailnet opens the https URL, pairs, PWA installs; toggle "Tailscale only"
  → LAN URL refuses, https still works; toggle serve off → handler gone.
