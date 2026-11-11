# Native iOS app for Alas

Status: design, 2026-11-11. iOS first; Android later.

## Intent

Alas already has a phone client: the remote web client (a PWA the Mac or
`alas-host` serves from `Alas/Resources/RemoteWeb/`). It works, and it is
how the owner gets by today, but a browser caps it: no push, hosts kept in
`localStorage`, weaker auth, a laggier chat, and no access to on-device
processing.

The native app exists for two moments away from the Mac:

1. **Being pulled in.** An agent needs a permission, an answer, or a plan
   decision. The phone buzzes; one tap lands on that request.
2. **Steering on the go.** Read what an agent did, redirect a running turn,
   queue follow-ups, start new work.

Both depend on a transcript that is as faithful as the Mac's. Prior art the
owner likes: the t3code and Superconductor mobile apps, with Alas's own twist
coming later.

## Goals (v1, first TestFlight)

- **1:1 parity with today's remote web client.** The list below is the full
  scope; it matches the client messages `RemoteWeb/` actually sends (it has
  no terminal or git-mutation flows):
  - hub of several paired Macs/hosts, including federated sessions a gateway
    Mac re-exports (`serverId:sessionId`);
  - session list grouped by repo and worktree, search, All/Running/Dirty
    filters, attention and running badges;
  - full transcript: user, agent, thought, tool call, file edit, plan, plan
    document, visual aid, system notice, failure incident rows; attached
    images; older-history paging;
  - composer with `/` commands, `@` mentions, image attachments; stop; steer
    a running turn; token usage;
  - prompt queue (force-send, remove, retry, edit, clear, move, promote);
  - take over (writer lease);
  - permission, question, plan accept/reject, and elicitation form requests;
  - session config (model, mode, agent options, auto-run), rename;
  - Changes tab (file list + diff) and Files tab (tree + file viewer);
  - new session on an existing worktree, or a new worktree (repo, base
    branch, branch name) then agent;
  - visual aids (agent HTML in a locked-down web view, answer/dismiss);
  - add/re-pair/forget hosts.
- **Push notifications** whenever a session needs the owner: permission,
  question, plan decision, elicitation, and a visual aid waiting for an
  answer. Tapping opens that request. Turn finished and failure do not push
  in v1; per-type opt-in toggles come later. *(My call; the owner asked for
  "when an agent needs my approval".)*
- **Allow / Deny from the notification** for permission requests. *(Builder's
  call, agreed in principle: worth it, but it may slip past the first build
  if it fights iOS background limits.)*

## Non-goals for v1

Terminals, port forwarding, git mutations (commit/push/PR), the Inbox,
on-device AI, Bonjour discovery from the phone, iPad-specific layout, Android.
These are the "go from there" list; the design must not block them.

## Anti-goals (fails even if it "works")

- **A transcript that is laggier or jankier than the web client.** Performance
  is the owner's top concern. Streaming output, scrolling long sessions, and
  opening a session must feel instant and hold 120 Hz on ProMotion phones.
- **A generic-looking app.** It must look stunning, with real design care. A
  default-styled SwiftUI list app is a failure.
- **Anyone else's usage costing the owner money.**
- **Notification content leaving the owner's machines** via the relay.

## Decisions

### Platform and code sharing

- **iOS first, SwiftUI, native.** Android (Kotlin/Compose) follows once iOS
  settles; the web client stays as the fallback and keeps working.
- **Share Swift with the Mac.** The protocol (`RemoteProtocol`,
  `RemoteMessageWireJSON`, `HostProtocol`) lives in
  `Packages/AlasCore/Sources/AlasHostCore/Remote/Protocol/` and
  `.../Core/`, in a package that only declares `.macOS(.v15)` and whose
  modules pull in server-side code. Transcript row bodies (`json`) are the
  encoded ACP model types (`ACPMessage.ToolCall`, `.FileEdit`, `.PlanItem`,
  `ACPPlanDocument`, `ACPVisualAid`), which the Mac's own peer client already
  decodes (`Alas/Sources/Remote/Native/NativePeerTranscriptPresentation.swift`).
  So the work is to make the wire types and the ACP value types they
  reference **build for iOS**, not to invent a new schema.
- **Reuse the Mac's native client logic.** The Mac's paired-host views
  (`Alas/Sources/Remote/Native/`, ~9.6k lines, mostly Foundation-only) and
  `RemotePeerConnection` already speak this protocol, including transcript
  delta sync and the `.host` channel. Move the UI-free parts the phone needs
  (connection, hello/version handling, transcript sync and windowing, row
  decoding, queue/request state) into shared, iOS-buildable code that both
  the Mac app and the iOS app use, rather than writing a second client.
- **Android later gets a contract, not a port of guesses.** When Android
  starts, derive a schema and generated Kotlin models from the shared Swift
  types. Not v1 work.

### Connectivity and hosts

- Same reachability as today: LAN or Tailscale (and Tailscale Serve HTTPS).
  No new relay for traffic, no NAT traversal.
- Hosts are stored natively (Keychain for secrets), with all advertised
  origins per host. The app picks a working origin automatically, preferring
  tailnet, as `hub-links.js` does.
- Plain HTTP/WS to LAN and tailnet addresses needs App Transport Security
  exceptions and the Local Network usage description in the app's Info
  properties.
- Pairing reuses the existing QR/link format
  (`Pairing/RemotePairingLink.swift`): scan in-app, or paste a link, or enter
  address + code. Scanning the Mac's QR with the system camera should also
  land in the app when installed (builder's call how).

### Pairing security (my call; not discussed in detail)

The web client gets a bare bearer token (`kind: browser`). The native app
holds an Ed25519 identity key in the Keychain and proves it, as paired Macs
already do (`Identity/RemoteIdentityKey.swift`), so a leaked token alone is
not enough. This needs a server-side change on the Mac and `alas-host` to
accept and pin a key for phone devices. Shape *(my call)*: the phone sends
its public key as an extra optional field on `POST /pair`; new hosts record
the device as a new kind (`mobileApp`, full scope, key pinned, shown
separately in the Mac's device list); older hosts ignore the field and issue
a plain `browser` token, which the app flags as less secure. That keeps the
wire change additive under protocol version 1.

### Push

How others do it: t3code runs a managed relay behind accounts (Clerk etc.);
Happy relays all traffic through its server; Superconductor runs the agents in
its own cloud. Alas needs much less, because the phone already reaches the
Mac directly.

- **A push-only relay on Cloudflare Workers (free plan).** It holds the APNs
  key (and later the FCM key) and forwards pings. APNs/FCM cost nothing; the
  free Workers plan cannot bill: past its daily quota requests fail. Worst
  case if usage grows: push pauses until the owner decides. Nobody pays.
- **No accounts.** The phone registers its APNs token with the relay and gets
  back an unguessable relay token. The phone hands that relay token to each
  Mac at pairing (and refreshes it over the socket when it changes). The relay
  forwards only for registered tokens and rate-limits per token.
- **Content-free payloads.** The relay sees only opaque identifiers (host id,
  session id, request id, request type), never prompt or tool text. A
  Notification Service Extension on the phone connects to the host and
  rewrites the alert into something readable ("Claude wants to run …") before
  it is shown; if the host is unreachable in time, the generic alert stands.
- **Who sends.** The Mac app and `alas-host` both send, when a session enters
  a needs-the-owner state, to every paired phone that registered a relay
  token. Use the existing attention signal; don't invent a second one.
  Suppress or collapse duplicates (one per request; clear when resolved
  elsewhere, e.g. answered on the Mac).
- **Federated sessions.** A host pushes only for sessions a phone paired
  with it can see, including peer sessions it re-exports as a gateway; the
  Notification Service Extension and Allow/Deny talk to the host that sent
  the push, which forwards as it already does for federated sessions. The
  push identifier is the session's origin `serverId` + request id, used as
  the APNs collapse id, so a phone paired with both gateway and origin host
  sees one alert. *(My call.)*
- **Shared quota and abuse.** While the app is TestFlight-only, the minimal
  relay is enough. Before the App Store release, registration gets App
  Attest and per-install limits, and the relay URL stays a setting so
  anyone can point at their own deployment; the App Store privacy
  disclosure covers the relay. *(My call; the owner's rule is that nobody
  else's usage may cost money, and the free plan guarantees that.)*
- **APNs from Workers.** Workers' `fetch()` speaks HTTP/2, JWT signing is
  WebCrypto ES256, and a Workers APNs client exists
  (`@fivesheepco/cloudflare-apns2`) as a reference. Verify a real delivery
  first. Fallback if it fails: Worker → FCM HTTP v1 (which forwards to APNs
  and is also Android's path). The Mac never holds the APNs key. *(My
  call.)*
- **Relay code lives in this repo** (location builder's call) and is deployed
  to the owner's Cloudflare account. The relay URL is a host setting with a
  sane default.

### Distribution

TestFlight first; App Store later. Use the final bundle identifier, push
entitlement, and signing from day one so going public is a release step,
not a migration. *(My call.)*

- **Bundle ID: `io.nlopez.alas`** (owner's decision), the same identifier as
  the Mac app, under the same Apple team. The Mac app ships outside the App
  Store, so this only reserves the option of a shared listing later.
  Extensions hang off it (e.g. `io.nlopez.alas.NotificationService`).
- Debug builds mirror the Mac's split: a separate dev identifier
  (`io.nlopez.alas.dev`) so development installs never replace the
  TestFlight app. *(My call.)*

### Performance bar

- 120 Hz on ProMotion while an agent streams into the visible transcript and
  while flinging through a long session.
- Opening a session shows the latest content immediately (windowed snapshot +
  paging, as the protocol already supports), no layout of the whole history.
- Cold start to a usable session list fast enough to feel native; reconnect
  on foreground without a visible "loading" state when data is cached.
- Measure it: frame-time instrumentation on a real device with a large,
  actively streaming session, compared against the web client in Safari on
  the same phone. The Mac's transcript history (tail-follow livelock,
  content-height feedback loops) shows lazy self-sizing stacks are the main
  risk; prove the rendering approach with an early spike before building
  every row type on it.

### Design

The owner wants it to look stunning and native, with care. Before building
screens, produce mockups of the key surfaces (session list, transcript with
each row kind, request sheets, composer, host list) for the owner to react to.
Follow current iOS design language. The Mac's `DesignScale` work is the
visual reference for Alas's identity, adapted to iOS rather than copied.

## Constraints

- AGENTS.md rules apply: English everywhere, Conventional Commits, Swift
  Testing, `project.yml` + `xcodegen` for project changes, AlasCore stays
  free of UI frameworks and app-only deps, `swift test --package-path
  Packages/AlasCore` must keep working.
- The Mac app and `alas-host` must keep serving the web client unchanged.
- Protocol changes stay additive under `RemoteProtocolVersion` 1 unless a
  break is unavoidable. The phone must cope with older hosts (use `hello`
  capabilities and `hostVersion`).
- Tests follow the repo's testing policy: pin protocol decoding, sync and
  windowing logic, origin selection, push dedup; no view-composition tests.

## Left to the builder

- How to split the package so the protocol, ACP value types, and client logic
  build for iOS (new targets vs. adding iOS to existing ones).
- Where the iOS target lives (same `project.yml` is the default) and its name.
- Transcript rendering technology, provided it meets the performance bar.
- Markdown rendering and syntax highlighting approach on iOS.
- Visual aid host (WKWebView with the same sandbox/CSP as `visual-aid.js`).
- Relay implementation details, storage (KV/D1), and rate limits.
- Order of work, as long as the transcript performance spike and the design
  mockups come before mass screen building.
