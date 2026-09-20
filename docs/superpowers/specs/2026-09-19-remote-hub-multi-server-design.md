# Remote Hub: Multi-Server Client Design

## Context

The remote web client is served by each Mac from `Alas/Resources/RemoteWeb`
over plain HTTP on a LAN or tailnet address. Every part of it assumes exactly
one server: the WebSocket URL is built from `location.host`, the token lives in
a single `localStorage` key (`alas.remote.token`), the `?code=` pairing flow
posts to the page's own origin, and the QR encodes that Mac's own URL. The
server has no notion of its own identity, no protocol version field, no
`Origin` check, and no CORS headers. The client's Settings tab exists but is
disabled.

The goal is a hub: one installed client that holds credentials for several
Macs, shows which are online and which need attention, and switches between
them. This document covers phase 1, which is origin-agnostic. The hub is still
served by one of the user's Macs. Hosting it on an HTTPS origin, camera QR
scanning, push notifications, and any relay are later phases and are out of
scope here.

Existing conventions this design follows: pure client logic lives in standalone
scripts (`worktree-creation.js`, `session-ordering.js`) with node tests under
`scripts/tests/`; `RemoteWebAssetTests` asserts script tag order, the `sw.js`
precache list, and `?v=` bumps; server behaviour is covered by the suites in
`AlasTests/Remote`.

## Goals

- Pair several Macs into one client, each with its own token, name, and
  ordered address list.
- Switch between paired Macs without reloading the page or reconnecting.
- Show, for every paired Mac while the page is visible, whether it is online
  and how many of its sessions are awaiting permission or input.
- Connect to whichever of a Mac's advertised addresses answers, so moving
  between LAN and tailnet needs no manual change.
- Distinguish an unreachable Mac from one that revoked the device's token.
- Keep the single-server flow working unchanged for a fresh phone that scans
  a QR.
- Give the server a stable identity and a protocol version so a client served
  by one Mac can talk safely to another running a different Alas version.

## Non-Goals

- HTTPS, TLS certificates, Tailscale Serve integration.
- Camera-based QR scanning inside the client.
- Web Push or any phone-side notification.
- A relay or hosting the bundle on `alas.build`.
- Remembering the last open session per server.
- Any change to the session, queue, changes, or files protocol messages.
- Per-client nicknames for servers; the name is whatever the Mac advertises.
- Legacy Macs (pre-hub Alas) joining a hub. They keep working as single-server
  origins; only a Mac running this change can be added to a hub, because
  adding one requires the CORS and Origin handling below.

## Feature Flag

The user-visible hub UI ships behind an experiment toggle, following the
`workspacesEnabled` and `needsAttentionEnabled` precedent:

- `AppConfig.Remote.hubEnabled: Bool`, default `false`.
- A **Remote hub** row in Settings, Advanced, Experimental: "Lets the remote
  web client pair with several Macs and switch between them."
- The Mac reports the value in `hello` as `hubEnabled`.

Client behaviour is keyed on whether **any known paired server**'s cached
`hubEnabled` is `true` — not just the currently active one:

- No paired server has ever reported `hubEnabled: true`: the status chip,
  disabled Settings tab, and gates behave exactly as today. The registry
  migration still runs and the link manager still owns the single active
  link, so there is one code path, but no idle links are created and no hub
  UI is rendered.
- At least one paired server has reported `hubEnabled: true` (whether or not
  it is the one currently active): the server chip, Servers section, add
  sheet, idle links, and badges are enabled.

This is an aggregate over the whole registry, not a per-server flag re-read on
every switch, so that once a user has opted into the hub on their hub Mac,
switching to view a different, non-hub-toggled Mac never hides the hub UI or
strands them without a way back to it — a per-active-server check would do
exactly that, since the newly active Mac's own hello would report `false`.

Only the Mac used as the hub needs the toggle on. Macs being *added* need only
the ungated server groundwork below (identity, hello, Origin policy, CORS,
pairing link). The **Copy pairing link** button in the Remote pane is shown
regardless, since it is harmless and useful for a hub on another Mac.

Everything server-side in this document ships ungated because it is additive,
and the Origin policy accepts allowlisted hosts so existing reverse-proxy
setups keep working. Once the hub has been exercised across the author's
Macs, the flag is removed and the behaviour becomes the default.

## Server Identity and Protocol Version

`AppConfig.Remote` gains two fields:

- `serverId: String` — a UUID string generated the first time it is read as
  empty (on first enable or first load after upgrade) and persisted.
- `displayName: String` — defaults to `Host.current().localizedName`, editable
  in the Remote settings pane. Empty means "use the default".

`RemoteProtocol` gains `static let protocolVersion = 1` and a new
server-to-client message:

```json
{ "type": "hello", "protocolVersion": 1, "serverId": "…", "name": "…", "hubEnabled": true }
```

`RemoteConnection` sends `hello` as the first frame after a successful upgrade,
before any reply to client messages. `/remote-info` also includes `serverId`
and `name`.

Client rules:

- A socket that produces messages without a preceding `hello` is a **legacy**
  server. The client drives it exactly as today and shows "Older Alas" in its
  server row.
- `protocolVersion` is recorded per server for diagnostics. Phase 1 refuses
  nothing on mismatch; the message set is backward compatible because every
  new field is optional on both sides.

## Pairing Link

The QR and a new **Copy pairing link** button in the Remote pane produce the
same string:

```
http://<preferred-host>:<port>/?code=<CODE>&hosts=<origin1>,<origin2>,…
```

- The base URL is the preferred advertised address, as today, so a fresh phone
  scanning the QR still opens that Mac's page and pairs against its own origin.
- `hosts` is a comma-separated list of full origins (`http://100.64.1.5:8765`),
  in `RemoteNetwork` rank order, preferred first, percent-encoded as a query
  value. The base URL's own origin is always included.
- A pure function `RemotePairingLink.build(code:addresses:port:)` produces the
  string and is unit tested; `RemoteServerPane` calls it for both the QR and
  the copy button.

Client parsing accepts:

- a full pairing link (the `hosts` list and `code`);
- a link without `hosts` (legacy QR), which yields a single origin from the
  URL itself;
- the manual fallback: an address (`host:port` or a full origin) plus a code.

Pairing tries each origin in order with a per-attempt timeout (4 s). A network
failure or timeout moves to the next origin. An HTTP `401` from any origin
stops the attempt and reports an expired code. Success stores the token and
the full origin list, then connects; the `hello` provides `serverId` and
`name`.

## Cross-Origin Hardening

A hub served by Mac A must be able to `POST /pair`, `GET /health`, and open
`/ws` against Mac B. Browsers send an `Origin` header on all of these.

**Origin policy.** A new `RemoteOriginPolicy` next to `RemoteAccessPolicy`.
When a request carries `Origin`, it is allowed only if the scheme is `http` or
`https` and the host is one of:

- loopback (`localhost`, `127.0.0.0/8`, `::1`);
- RFC 1918 private (`10/8`, `172.16/12`, `192.168/16`);
- the CGNAT range Tailscale uses (`100.64/10`) or the tailnet IPv6 prefix;
- IPv6 unique-local (`fc00::/7`) or link-local (`fe80::/10`, `169.254/16`);
- a name ending in `.local`;
- a host already accepted by the `RemoteAccessPolicy` Host allowlist, which
  includes `AppConfig.Remote.allowedHosts`, so an existing reverse-proxy
  hostname keeps working without new configuration;
- an entry in the new `AppConfig.Remote.allowedOrigins: [String]` list, for
  origins that are not also valid Host values (phase 2's hosted hub).

The classifier reuses `RemoteNetwork`'s address classification. Requests with
no `Origin` (non-browser clients, same-origin navigations) pass as today. The
policy applies to the WebSocket upgrade, `POST /pair`, `OPTIONS /pair`, and
`GET /health`. A rejected origin gets `403 Forbidden` and, for the upgrade,
the socket is closed without upgrading. Static assets and `/remote-info` stay
subject only to the Host allowlist. Phase 2 will add the hosted hub origin to
the default allowed list.

**CORS.** For an allowed `Origin`, responses to `POST /pair`, `GET /health`,
and `OPTIONS /pair` carry:

```
Access-Control-Allow-Origin: <the request's Origin>
Vary: Origin
```

`OPTIONS /pair` additionally returns `204` with
`Access-Control-Allow-Methods: POST`,
`Access-Control-Allow-Headers: content-type`, and
`Access-Control-Max-Age: 600`. The client keeps the pair request a "simple"
request (no explicit `Content-Type`), so the preflight is a safety net rather
than a hot path.

**Why not an authenticated cross-origin risk.** Authentication remains the
bearer token presented as the WebSocket subprotocol, never a cookie, so a
foreign page cannot ride an existing session. The Origin policy hardens the
pairing route against a public site attempting code redemption from a phone
browser and keeps a defined boundary for the hosted origin in phase 2.

## Client Storage

One `localStorage` document, key `alas.remote.hub`, replaces the token key:

```json
{
  "version": 1,
  "activeId": "c-…",
  "servers": [
    {
      "id": "c-…",            // client-local id, generated on add
      "serverId": "…" | null, // from hello; null until first connect / legacy
      "name": "Nacho's MacBook",
      "origins": ["http://100.64.1.5:8765", "http://192.168.1.20:8765"],
      "lastOrigin": "http://100.64.1.5:8765",
      "token": "…",
      "protocolVersion": 1 | null,
      "hubEnabled": false, // from hello; the aggregate flag check above ORs this over every entry
      "addedAt": 1758300000000
    }
  ]
}
```

Migration on first load: if `alas.remote.token` exists and the hub document
does not, create one server entry with `origins = [location.origin]`,
`name = location.hostname`, mark it active, and remove the old key.

Adding a server with a code in the URL (`?code=`) on a page that already has
servers adds or re-pairs: after pairing, match by `serverId` from `hello`; if
the server is legacy, match by any overlapping origin. A match replaces the
token and merges the origin list, preserving today's "scanning a fresh code
replaces a stale token" semantics. `history.replaceState` strips the query as
today.

A new pure module `hub-registry.js` (global `RemoteHubRegistry`, node-testable
like the others) owns: document load/save/migrate, pairing-link parsing, the
add/merge/forget operations, active-server selection with the launch fallback,
and attention/running aggregation over session lists.

## Link Manager

A new module `hub-links.js` (global `RemoteHubLinks`) owns one **link** per
server. It takes a WebSocket factory and a fetch function so state
transitions are unit testable.

Link states: `idle`, `connecting`, `online`, `offline`, `unauthorized`.

- **Connect.** Try `lastOrigin` first, then the remaining origins in order,
  each with a 4 s handshake timeout. The first socket that opens wins; the
  others are abandoned. The winning origin becomes `lastOrigin`. If none
  opens, the link is `offline` and retries with the existing backoff
  (1.5 s doubling to a 30 s cap).
- **Hello.** The first message, if it is `hello`, updates `serverId`, `name`,
  and `protocolVersion` in the registry. Any other first message marks the
  link legacy.
- **Active link.** Exactly one link is active. Its socket is the one the
  existing app code drives via `ws` and `send`; all existing handlers, the
  gate overlay, reconnect chip, and escalation logic apply to it unchanged.
- **Idle links.** Receive `hello`, then send `listSessions` every 30 s while
  `document.visibilityState === "visible"`. From each `sessionList` they
  derive `attention` (sessions with status `awaitingPermission` or
  `awaitingInput`) and `running` (status `streaming`). They ignore every
  other message.
- **Visibility.** On `hidden`, idle links close their sockets and cancel
  timers. On `visible`, every link reconnects. The active link keeps today's
  behaviour.
- **Revocation detection.** When a link's socket fails to open on an origin,
  the link probes `GET /health` on that origin (CORS allowed above). If the
  probe succeeds but the upgrade failed, the state is `unauthorized`; its row
  says "Pair again" and the link stops retrying until re-paired. If the probe
  also fails, the state is `offline`. The active link reuses this to replace
  the generic "Can't reach Alas" gate with a "Pair again" gate when the token
  was revoked.

## Switching

`switchServer(id)`:

1. Persist `activeId`.
2. If the old active link has an open session, send `unsubscribe` so the Mac
   stops tracking its transcript.
3. Run `resetServerScopedState()`, a single function that clears every
   per-server global in `app.js`: session list and titles, current session,
   transcript map and nodes, transcript meta, queue items, session config,
   pending and last-sent attachments, create sheet state, changes state, file
   tree state, detail stack, repo filter overrides, dismissed prompts; and
   resets the views to the Repos tab list level.
4. Bind the app to the new link's existing socket. No reconnect. If the new
   link is not `online`, the gate shows its state (connecting, offline, or
   pair again).
5. Send `listSessions` and continue as after a normal `onopen`.

On launch the hub activates `activeId` if present. If that link fails to come
online within the existing 5 s grace while another link is `online`, the hub
switches to the first online server and says so in the status chip. The old
active server stays in the list.

## User Interface

**Header.** The status chip becomes a server chip: the active server's name
plus its connection state colour. Tapping it opens the Settings tab.

**Settings tab.** Enabled. It contains a **Servers** section:

- One row per server: name (or "Older Alas" hint for legacy), the origin in
  use, a status dot (online, connecting, offline, pair again), and attention
  and running badges. The active row is marked. Tapping a non-active row
  switches.
- Per-row actions via a trailing menu: **Re-pair** (opens the add sheet
  pre-targeted at this server) and **Forget** (confirm, then remove; if it was
  active, switch to the first online server or show the empty state).
- **Add server** button opening a sheet with one text field that accepts a
  pasted pairing link, a disclosure for the manual fallback (address and
  code), and an inline error line.
- The tab bar's Settings icon carries the sum of `attention` over non-active
  servers.

**Empty state.** With no servers (fresh page, no `?code=`), the existing
"Pair this device" gate is shown with an added "or paste a pairing link"
action that opens the add sheet.

**Mac side.** The Remote pane gains a **Server name** text field above the
pairing section and a **Copy pairing link** button beside the QR. The QR help
text mentions that the link can be pasted into another device's Alas remote.

## Service Worker and Assets

`sw.js` returns early for any request whose `url.origin !== location.origin`,
so cross-origin pairing, health, and socket requests are never intercepted or
cached. The path-based bypass list stays for same-origin requests. Cache name
and `?v=` versions bump; `RemoteWebAssetTests` and the precache list gain the
two new scripts. The manifest is unchanged.

## Error Handling

| Situation | Where | Message |
|---|---|---|
| Link does not parse | add sheet | "That doesn't look like an Alas pairing link." |
| Every origin unreachable | add sheet | "Couldn't reach that Mac at any of its addresses." |
| Code expired (`401`) | add sheet | "That code expired. Tap New code in Alas and try again." |
| Server already paired (same `serverId`) | add sheet | Treated as re-pair; row shows "Re-paired". |
| Token revoked | row and active gate | "Pair again" with a button to the add sheet. |
| Legacy server | row | "Older Alas" hint; still switchable. |
| Origin rejected by Mac (`403`) | add sheet | "That Mac doesn't allow this address. Add this hub's address to Allowed origins in its Remote settings." |
| Home Mac offline at launch | page | Shell loads only if a service worker cached it, which on iOS needs HTTPS. Documented limitation for phase 2. |

## Security

- Tokens remain per device per Mac, presented as the WebSocket subprotocol,
  never in cookies. Forgetting a server deletes its token locally; revoking on
  the Mac invalidates it server-side and now surfaces as "Pair again".
- The pairing code is never logged; `?code=` is stripped from the URL as
  today.
- The Origin policy defaults to private-network origins only, so a public web
  page cannot pair or connect even if it learns a Mac's address.
- `hosts` in the pairing link reveals a Mac's private addresses to whoever
  sees the QR or clipboard. That is the same information the QR already
  carries for one address, and the code is single-use with a 120 s TTL.

## Testing

**Swift (`AlasTests/Remote`):**

- `RemoteOriginPolicyTests`: each allowed class, public IP and public DNS
  rejected, Host-allowlisted names accepted, `allowedOrigins` honoured, absent
  Origin allowed, malformed Origin rejected.
- `RemoteHTTPResponderTests` (new): CORS headers on `/pair` and `/health`
  for an allowed origin, absent for a disallowed one, `OPTIONS /pair`
  returns 204 with the method and header allowances, `403` on rejected
  origin.
- `RemoteServerIntegrationTests` (extend): the first frame after upgrade is
  `hello` with the configured `serverId` and name; a disallowed Origin on the
  upgrade closes without 101.
- `RemotePairingLinkTests`: link built from ordered addresses, encoding, the
  base origin always present.
- `RemoteConfigTests` (extend): `serverId` generated once and stable across
  reloads; `displayName` default and override; `hubEnabled` defaults to
  `false` and round-trips.
- `RemoteServerIntegrationTests` (extend): `hello` carries `hubEnabled`
  matching the config.
- `RemoteWebAssetTests` (extend): new scripts in tag order and precache list.

**Node (`scripts/tests/remote-web-hub/`):**

- Registry: legacy token migration, link parsing for all three input shapes,
  add and merge by `serverId` and by origin overlap, forget with active
  fallback, launch selection, attention and running aggregation.
- Flag: with `hubEnabled` false in the active hello, no idle links are
  created and the hub UI hooks are not invoked; flipping to true on a later
  hello enables them.
- Links: with an injected socket factory, origin fallback order and timeout,
  `lastOrigin` promotion, hello handling and legacy detection, idle polling
  gated on visibility, unauthorized versus offline via the injected fetch,
  and the backoff schedule.

**Manual:** pair two Macs, switch both ways while a session streams, revoke
the device on one Mac and confirm "Pair again", forget a server, quit the home
Mac's Alas after launch and keep driving the other Mac, and scan a fresh QR on
a phone with no prior pairing.

## Open Questions

None for phase 1. Phase 2 decisions (HTTPS origin on `alas.build`, Tailscale
Serve integration, camera scanning) and phase 3 (push) are deferred to their
own specs.
