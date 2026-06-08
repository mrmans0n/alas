# Remote LAN and Tailnet Access Design

## Goal

Make Alas Remote dependable and explicit for private-network access. The target
environment is a trusted LAN or tailnet, not public internet exposure and not a
relay-backed service.

This slice hardens and clarifies the existing PWA/server path:

- Keep direct LAN IP access working automatically.
- Prefer tailnet addresses when they are detected.
- Add host validation to reduce DNS-rebinding and accidental exposure risk.
- Improve Settings so users understand which address they are pairing and using.
- Add safe diagnostics for health and setup troubleshooting.

## Current Context

Alas already ships a static remote web client from `Alas/Resources/RemoteWeb`.
`RemoteServer` serves that bundle, handles `POST /pair`, and upgrades authorized
`/ws` requests to a WebSocket bridged through `RemoteSessionGateway`.

The current Settings pane shows one computed address:

```text
http://<primary IPv4 or localhost>:<bound port>
```

That works for live LAN/tailnet access, but the system does not yet separate
LAN and tailnet addresses, validate inbound hosts, or provide a safe diagnostic
endpoint. The existing PWA shell is useful, but browser install/offline behavior
can still be limited when the phone opens an insecure LAN HTTP origin.

## Non-Goals

This design does not add:

- A public relay.
- End-to-end relay encryption.
- HTTPS certificate generation or trust-store management.
- Terminal streaming in the PWA.
- Worktree creation, git mutation, PR creation, or CI/review controls.
- Offline transcripts, queued prompts, or offline permission decisions.

Those are later slices. This one makes direct private access safer and easier to
operate.

## Architecture

Keep the current in-process server and add a small access policy layer before
request dispatch.

The server continues to own these surfaces:

- Static PWA assets: `GET /`, `GET /index.html`, `GET /app.js`, and related
  files.
- Pairing: `POST /pair`.
- Live control: WebSocket `GET /ws`.
- Diagnostics: `GET /health` and `GET /remote-info`.

The access policy validates the request `Host` header before route handling for
every request, including static assets. Valid LAN IP and tailnet IP hosts remain
accepted automatically. Pairing and WebSocket remain gated by their existing
code/token mechanisms after the host check passes.

## Components

### RemoteAccessPolicy

A pure Swift type that answers whether a parsed request host is acceptable.

Allowed hosts:

- `localhost`.
- `127.0.0.1`.
- `::1`.
- The currently detected local interface IP addresses.
- Configured hostnames in `AppConfig.Remote.allowedHosts`.
- The machine's own local hostname and `<hostname>.local` when known.

LAN IPs must continue to work. If the Mac has `192.168.x.x`, `10.x.x.x`, or
`172.16-31.x.x` on an active interface, requests whose `Host` header uses that
IP are accepted without the user adding a manual allowed host.

Unknown hostnames are rejected with `403 Forbidden` before pairing-code
redemption or WebSocket authorization is attempted.

### RemoteAdvertisedAddress

A small model for addresses shown in Settings:

```swift
struct RemoteAdvertisedAddress: Equatable, Identifiable {
    enum Kind: String, Codable {
        case localhost
        case lan
        case tailnet
        case custom
    }

    let id: String
    let kind: Kind
    let interfaceName: String?
    let host: String
    let port: UInt16
    let url: String
    let isRecommended: Bool
}
```

Implementation can add fields, but these fields are the required behavioral
surface for Settings and diagnostics.

### LocalNetwork Expansion

Replace the single `primaryIPv4()` helper with address enumeration.

Rules:

- Include loopback for same-machine testing.
- Include active non-loopback IPv4 addresses.
- Classify `en*` private IPv4 addresses as LAN.
- Classify `utun*` private/tailnet-looking addresses as tailnet candidates.
- Prefer tailnet addresses first when present, then LAN, then localhost.
- Keep returning a simple primary address helper if existing call sites need it.

The implementation should avoid depending on Tailscale-specific APIs. Interface
and address classification is enough for this slice.

### RemoteHTTPResponder

Add two safe diagnostic routes:

- `GET /health`: returns `200 OK` with minimal JSON, for example
  `{"ok":true}`.
- `GET /remote-info`: returns safe setup metadata only.

`/remote-info` includes:

- App name.
- Bound port.
- Advertised addresses.
- `usesPlainHTTP: true` for this direct server slice.
- Paired device count.

It can also include app version/build if that is already available through an
existing helper.

It must not include:

- Pairing codes.
- Device tokens or token hashes.
- Session titles.
- Transcript data.
- File paths.
- Worktree names.

### RemoteServerPane

Replace the single address row with an address list:

- Tailnet address first when detected.
- LAN address next.
- Localhost for same-machine testing.
- Configured custom hostnames when present.

The user can choose the address used for QR generation. QR generation continues
to use:

```text
<selected-url>/?code=<pairing-code>
```

Settings should also show:

- Server status and bound port.
- A concise plain-HTTP PWA caveat.
- Paired devices with last-seen status.
- Connected-now state from a read-only `RemoteServer` snapshot of authenticated
  device ids or per-device connection counts.
- A "Revoke all devices" action.

### AppConfig.Remote

Add:

```swift
var allowedHosts: [String] = []
var preferredAdvertisedHost: String? = nil
```

Existing configs continue to decode successfully. Empty `allowedHosts` means
auto-detected localhost, LAN IPs, tailnet IPs, and the machine local hostname are
accepted. It does not mean "allow every host".

## Request Behavior

Host validation runs before route-specific handling.

For accepted hosts:

- Static assets behave as they do now.
- `POST /pair` keeps the current pairing-code flow and rate limiting.
- `/ws` keeps the current paired-device token flow.
- `/health` and `/remote-info` return safe JSON.

For rejected hosts:

- Return `403 Forbidden`.
- Do not attempt pairing redemption.
- Do not attempt WebSocket token validation.
- Do not log the full request URL.

The server should strip any port from the `Host` header before host matching and
handle IPv6 bracket syntax.

## PWA Behavior

The remote web client remains live-first.

The service worker stays limited to static shell assets. Network-only paths:

- `/pair`
- `/ws`
- `/health`
- `/remote-info`
- Future `/api/*`
- Non-GET requests

No transcript, session list, permission request, or prompt data is cached in
this slice.

The web UI can keep the existing unreachable gate. Settings should communicate
that full PWA install/offline behavior may be limited over plain HTTP LAN IPs.
The app should not promise offline session control.

## Security And Privacy

Principles:

- LAN/tailnet direct access is an explicitly private-network feature.
- Pairing codes remain short-lived and single-use.
- Device tokens remain per-device and are never stored in plaintext server-side.
- Host validation rejects unexpected browser origins before auth handling.
- Tokens, pairing codes, and URLs containing `?code=` are not logged.
- Diagnostics are safe to view from a paired or unpaired browser on an allowed
  host.

This does not make plain HTTP confidential. Users still need a trusted LAN or
tailnet. HTTPS, reverse-proxy docs, or Tailscale certificate support can be
designed later.

## Testing

Swift tests:

- `RemoteAccessPolicy` accepts loopback hosts.
- `RemoteAccessPolicy` accepts detected LAN IPs.
- `RemoteAccessPolicy` accepts detected tailnet IPs.
- `RemoteAccessPolicy` accepts configured custom hosts.
- `RemoteAccessPolicy` rejects unknown hosts.
- Host matching handles `host:port` and bracketed IPv6.
- `POST /pair` with a rejected host returns `403` and does not redeem a valid
  pairing code.
- WebSocket upgrade with a rejected host returns `403` before token validation.
- `/health` returns safe JSON.
- `/remote-info` excludes sessions, tokens, codes, paths, and transcripts.
- Address classification orders tailnet before LAN before localhost.

Remote web asset tests:

- Service worker keeps `/pair`, `/ws`, `/health`, `/remote-info`, and `/api/*`
  network-only.

Manual verification:

- Enable remote control.
- Confirm Settings lists localhost, LAN, and tailnet addresses as available.
- Select the LAN IP address, scan QR, and confirm the phone pairs and connects.
- Select the tailnet address, scan QR from a tailnet-connected phone, and
  confirm pairing and WebSocket control.
- Try an unknown host header with `curl` and confirm `403`.
- Revoke one device and all devices, confirming live sockets close.
- Stop Alas and confirm the PWA still shows the unreachable gate.

## Risks

- Interface classification may mislabel unusual VPNs. The custom host list gives
  users an escape hatch.
- Some users may expect HTTPS because of the PWA shell. The Settings caveat must
  be explicit that this slice optimizes private reachability and safety, not full
  browser install guarantees.
- Host validation bugs could break valid LAN access. The policy must be covered
  by focused tests and must explicitly include detected LAN IPs.

## Future Work

Potential follow-up specs:

- HTTPS or reverse-proxy guidance for stronger PWA installability.
- Tailnet-specific polish if a reliable Tailscale detection path is desired.
- Web push or a local notification bridge for phone alerts.
- Remote launch actions for new ACP sessions.
- Remote review/shipping actions: status, diff summary, push, create PR.
- Terminal streaming over the remote protocol.
- A CLI or MCP surface over the same private-access server.
