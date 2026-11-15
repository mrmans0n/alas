# iOS Push Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone buzzes when a session needs the owner, and one tap lands on it.
- A session needs the owner when it waits on a permission, a question, a plan decision, an elicitation, or a visual aid.
- The alert reads like "Claude wants to run `npm test`", not just "a session needs you".
- A permission alert offers Allow and Deny.
- Once the request is answered anywhere else, the alert goes away.

This is plan 4. Plans 3a (#2482), 3b (#2492) and 3c (#2496) brought the phone to web-client parity.

**Architecture:** Three pieces, each content-free on the wire.

- **Relay** (`relay/`, a Cloudflare Worker in plain JavaScript, no npm dependencies). It holds the APNs key.
  - `POST /register` takes the phone's APNs token. It returns a relay token: the APNs token sealed with AES-GCM under the relay's secret. The relay therefore stores nothing.
  - `POST /push` opens the relay token and sends an alert or a "clear" ping to APNs. Both carry only IDs.
- **Hosts** (`Packages/AlasCore`, shared by the Mac and `alas-host` through `RemoteServer`).
  - The phone hands each host its relay URL and relay token over the socket, with a new additive client message. The host stores them on the phone's `RemoteDevice`.
  - A `RemotePushNotifier`, owned by `RemoteServer`, watches every session's `streamingState` through `HostEvent.sessionChanged`, and the federation provider's peer rows.
  - When a session enters `awaitingPermission` or `awaitingInput`, the notifier pings every registered phone. When it leaves that state, it sends a clear ping.
- **Phone.**
  - Registers for remote notifications and hands the relay token to every host.
  - A Notification Service Extension connects to the host, reads the pending request, and rewrites the alert.
  - A tap opens the session from the Inbox tab, and a clear ping removes the delivered alert.
  - Allow and Deny answer through `TranscriptSession`.

**Tech Stack:** Swift 6, SwiftUI/UIKit and UserNotifications on iOS 26, `AlasRemoteKit`, `AlasHostCore`, Swift Testing. For the relay: Cloudflare Workers with WebCrypto, tested with `node --test` (Node 24, no dependencies).

**Spec:** `docs/superpowers/specs/2026-11-11-native-ios-app-design.md`, under "Goals" (push and Allow/Deny), "Push", "Distribution" and "Anti-goals". Plans 3a, 3b and 3c, in `docs/superpowers/plans/2026-11-14-ios-*.md`, carry over their Global Constraints.

## Global Constraints

- Everything in the Global Constraints of plans 3a, 3b and 3c still applies:
  - kit imports: Foundation, CryptoKit and Observation;
  - the `Phone*` typealiases;
  - the design guide and xcodegen;
  - Conventional Commits with no agent attribution;
  - `withObservationTracking` rather than `Observations {}`;
  - no pairing with the owner's running Alas.app; test hosts use an isolated `ALAS_APP_SUPPORT_DIR` and port 8799.
- **Wire stays additive under `RemoteProtocolVersion` 1.**
  - New client message type `"pushRegistration"`, with fields `relayURL: String` and `relayToken: String?`. A `nil` token unregisters.
  - The host advertises the hello capability `"push.relay.v1"`. The phone sends `pushRegistration` only to hosts that advertise it.
- **No content leaves the owner's machines.**
  - A host→relay body has exactly these fields: `relayToken`, `kind`, `collapseId`, `serverId`, `sessionId` and `status`.
  - `kind` is `"attention"` or `"clear"`. `status` is `"awaitingPermission"` or `"awaitingInput"`.
  - No titles, prompts, tool text, host names or paths go in.
  - The APNs payload carries the same IDs under the top-level key `"alas"`.
  - The relay's fallback alert text is fixed: title `"Alas"`, body `"An agent needs you."`.
- **Collapse id:** base64url, without padding, of the first 24 bytes of SHA-256 over `"\(originServerId)\u{0}\(sessionId)"`. That is 32 characters, under APNs' 64-byte limit.
  - `originServerId` is the host's own `serverId`. For a federated peer session, it is the peer's `serverId`.
  - `sessionId` is the session's ID on its origin host, so a gateway and its origin produce the same collapse id.
  - On iOS the collapse id becomes the notification's identifier, which is what a clear ping removes.
- **The relay URL comes from the phone**, not from a host setting. The phone registers with a relay and must hand its token to hosts that post to that same relay.
  - Hosts accept only an `https` URL of at most 512 bytes, and a token of at most 1,024 bytes.
  - This is a ruling against the spec's "host setting", for the same goal: a relay token is only valid at the relay that issued it.
- **Phone build settings:**
  - `ALAS_PUSH_RELAY_URL`: empty means push is off. Write it as `https:/$()/…`, because xcconfig treats `//` as a comment.
  - `ALAS_APS_ENVIRONMENT`: `development` for Debug, `production` for Release.
  - `ALAS_APP_GROUP`: `group.io.nlopez.alas.dev` for Debug, `group.io.nlopez.alas` for Release.
- **Bundle IDs:**
  - The extension is `$(PRODUCT_BUNDLE_IDENTIFIER).NotificationService`.
  - The shared keychain access group is `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER).shared`. The extension sets the app's identifier explicitly.
- **Relay rules:**
  - The relay accepts only these topics: `io.nlopez.alas` and `io.nlopez.alas.dev`.
  - Environment `sandbox` goes to `api.sandbox.push.apple.com`; `production` goes to `api.push.apple.com`.
  - Each relay token is rate-limited to 30 pushes a minute, through the Workers rate-limit binding `PUSH_LIMIT`. The code skips the limit when the binding is missing.
- **Push timing:**
  - An attention push has priority 10, push type `alert`, and `mutable-content: 1`. It expires after 1 hour.
  - A clear push has priority 5, push type `background`, and `content-available: 1`.
  - A host pushes once per entry into a waiting state, per phone. It sends no repeat while the state holds.
- No new Swift dependencies. The relay has no `package.json`; deploy with `npx wrangler`.
- The phone's notification text takes at most 178 characters. It reuses the request wording the Inbox cards already show.

## Review Focus

- **A phone forgets a host.** It sends `pushRegistration` with a `nil` token first, if the host is online, so the host stops pushing. Otherwise the host keeps pushing until APNs reports the token gone (410); the host then drops the registration.
- **The host restarts mid-wait.** The notifier starts with every session's current state and pushes nothing for waits that already existed. It must not page the owner for old waits on every launch.
- **A host is paired with the phone both directly and through a gateway.** The phone shows one alert, through the shared collapse id, and a clear ping from either host removes it.
- **The extension can't reach the host within 20 s.** The relay's fallback alert stands. It is never blank, never dropped, and never a crash.
- **Allow from the lock screen while the Mac holds the writer lease.** The answer goes through `TranscriptSession`'s take-over-and-resurface path. It is answered once, never twice. When it can't be answered in time, a local alert says "Couldn't answer. Open Alas to respond."

---

### Task 1: The relay Worker

**Files:**
- Create: `relay/src/index.js`, `relay/src/seal.js`, `relay/src/apns.js`, `relay/test/seal.test.js`, `relay/test/apns.test.js`, `relay/test/index.test.js`, `relay/wrangler.toml`, `relay/README.md`
- Modify: `.github/workflows/build.yml`: add a step after "Test AlasCore": `node --test relay/test`.

**Interfaces:**
- Produces:
  - `POST /register` takes `{"apnsToken": hex, "topic": string, "environment": "sandbox"|"production"}` and returns `200 {"relayToken": string}`.
    - It returns `400` for a bad body, or for a topic or environment not on the allowed list.
  - `POST /push` takes the host→relay body from Global Constraints and returns one of:
    - `204` when delivered;
    - `400` for a bad body;
    - `403` when the token won't open;
    - `410` when APNs reports the device gone (`410`, or `400 BadDeviceToken`);
    - `429` when rate-limited;
    - `502` for any other APNs failure.
- Secrets: `RELAY_SECRET` (at least 32 random bytes, base64), `APNS_KEY_P8` (the `.p8` PEM text), `APNS_KEY_ID`, `APNS_TEAM_ID`.

- [ ] **Step 1: Write the failing tests.**
  - `seal.test.js`:
    - `seal` then `open` round-trips `{apnsToken, topic, environment}`.
    - A token sealed under another secret, or with one character flipped, makes `open` return `null`.
    - Sealing the same input twice gives two different tokens, because of the random IV.
  - `apns.test.js`:
    - `apnsJWT` with a freshly generated P-256 PKCS#8 key returns a three-part token.
      - Its header decodes to `{"alg":"ES256","kid":<keyId>}`.
      - Its claims decode to `{"iss":<teamId>,"iat":<now>}`.
      - Its signature verifies with the public key.
    - `apnsRequest` builds the attention request from the push body and an opened token. Assert:
      - the URL, and its host for each environment;
      - the `apns-topic`, `apns-push-type`, `apns-priority`, `apns-collapse-id` and `apns-expiration` headers;
      - the JSON body: `aps.alert` holds the fixed text, plus `aps["mutable-content"] == 1`, `aps.category == "attention"`, `aps["thread-id"] == sessionId` and `alas == {serverId, sessionId, status}`.
    - It builds the clear request too, with `aps["content-available"] == 1`, no alert, and `alas.clear == true`.
  - `index.test.js`: drive the exported `fetch` with a stub `globalThis.fetch` and an env holding a generated key. Cover:
    - a register-then-push round trip that returns 204;
    - a tampered token, which returns 403;
    - APNs answering 410, which the relay returns as 410;
    - a disallowed topic, which returns 400;
    - an unknown path, which returns 404.
- [ ] **Step 2: Run `node --test relay/test`.** Expect failures: the modules don't exist yet.
- [ ] **Step 3: Implement `seal.js`:**
  - `seal(secret: string, payload: object) -> Promise<string>`;
  - `open(secret: string, token: string) -> Promise<object|null>`.
  - Derive an AES-256-GCM key from the secret with HKDF-SHA-256, salt `"alas-relay"`, info `"relay-token-v1"`.
  - The token is base64url of a 12-byte IV followed by the ciphertext.
- [ ] **Step 4: Implement `apns.js`:**
  - `apnsJWT(env, nowSeconds) -> Promise<string>`. It imports the PKCS#8 key from the PEM, signs ES256, and caches at module scope for 50 minutes.
  - `apnsRequest(body, opened, jwt, nowSeconds) -> Request`.
- [ ] **Step 5: Implement `index.js`.** It exports `{ fetch(request, env) }` and does the routing and status mapping above.
  - The rate-limit key is the first 16 hex characters of SHA-256 over the relay token.
  - Bodies over 4 KiB return `400`.
- [ ] **Step 6: Write `wrangler.toml`.**
  - Name `alas-push`, `main = "src/index.js"`, and a current `compatibility_date`.
  - A `[[ratelimits]]` binding named `PUSH_LIMIT` at 30 per 60 s.
- [ ] **Step 7: Write `README.md`.** It holds the owner's deploy steps:
  1. Create the APNs key.
  2. `npx wrangler secret put` each secret.
  3. `npx wrangler deploy`.
  4. Put the resulting URL into `ALAS_PUSH_RELAY_URL`.

  It also explains why the relay stores nothing.
- [ ] **Step 8: Run `node --test relay/test`.** All pass.
- [ ] **Step 9: Commit:** `feat(relay): add the push relay Worker`.

### Task 2: Phones register with hosts

**Files:**
- Modify:
  - `Packages/AlasCore/Sources/AlasRemoteKit/Protocol/RemoteProtocol.swift`: the `pushRegistration` case, its `CodingKeys` entry, its decode and its encode;
  - `Packages/AlasCore/Sources/AlasHostCore/Remote/Pairing/RemoteDevice.swift`;
  - `RemotePairingService.swift`;
  - `RemoteSessionGateway.swift`, in `handle(_:)`;
  - the hello capability list, `RemoteServerIdentity.hostCapabilities` or wherever `HostProtocolCapability` capabilities are served;
  - `Alas/Sources/Remote/Settings/RemoteServerPane.swift`: a "Notifications" caption on the device rows that have a relay.
- Test: extend the existing `RemoteProtocol` wire-coding suite and the `RemoteDevice` / `RemotePairingService` suite.

**Interfaces:**
- Produces:
  - `case pushRegistration(relayURL: String, relayToken: String?)` on `RemoteClientMessageOf`.
  - `public struct RemotePushRelay: Codable, Equatable, Sendable { public var url: URL; public var token: String }`.
  - `RemoteDevice.pushRelay: RemotePushRelay?`. It decodes with `decodeIfPresent`, so older files still load.
  - `RemotePairingService.setPushRelay(_ relay: RemotePushRelay?, for deviceID: UUID)`. It saves through `saveDevices()`.
  - `RemotePairingService.pushRelays: [(deviceID: UUID, relay: RemotePushRelay)]`.
  - The capability constant `"push.relay.v1"`.

- [ ] **Step 1: Write the failing tests.**
  - `pushRegistration` round-trips through the wire JSON, both with and without a token.
  - The decoded JSON has `"type":"pushRegistration"`, `"relayURL"` and `"relayToken"`, and the null case omits the token.
  - A `RemoteDevice` JSON without `pushRelay` decodes with `nil`.
  - `setPushRelay` persists across a reload of `FileDeviceStore`, and `nil` clears it.
- [ ] **Step 2: Run `swift test --package-path Packages/AlasCore --filter <suites>`.** Expect failures.
- [ ] **Step 3: Implement the wire case, the device field and the service methods.**
  - The gateway handles `.pushRegistration` only for a `.remotePeer(deviceID:)` caller with `.full` scope.
  - It validates the Global Constraints caps and the `https` scheme, then calls `setPushRelay`.
  - It silently drops anything invalid, as it does for other malformed verbs.
  - Advertise `"push.relay.v1"` in hello.
- [ ] **Step 4: Add the pane caption.** Show "Notifications" when `device.pushRelay != nil`. Keep it to one line, in the style of the existing device rows.
- [ ] **Step 5: Run the suites.** They pass. Then run the Mac build, as AGENTS.md describes for a change that no suite covers.
- [ ] **Step 6: Commit:** `feat(remote): let a phone register a push relay with a host`.

### Task 3: Hosts send pushes

**Files:**
- Create:
  - `Packages/AlasCore/Sources/AlasHostCore/Remote/Push/RemotePushPlanner.swift`: pure;
  - `Packages/AlasCore/Sources/AlasHostCore/Remote/Push/RemotePushNotifier.swift`;
  - `Packages/AlasCore/Sources/AlasRemoteKit/Push/RemotePushID.swift`: the collapse id, shared with the phone.
- Modify:
  - `RemoteServer.swift`: own the notifier, and start and stop it with the server;
  - `FederatedSessionsProvider.swift`: an `onPeerRowsChanged` callback, or an observable property the notifier can watch.
- Test: `AlasCoreTests/.../RemotePushPlannerTests.swift` (new: it is a new type); a `RemotePushID` case goes into the same suite.

**Interfaces:**
- Consumes: `RemotePairingService.pushRelays` and `setPushRelay` from Task 2.
- Produces:
  - `public enum RemotePushID { public static func collapseId(originServerId: String, sessionId: String) -> String }`, used by Task 6.
  - `struct RemotePushPlanner`, with:
    - `init(current: [Key: String])`, where `Key` is `(originServerId, sessionId)` and the value is the status string;
    - `mutating func update(_ statuses: [Key: String]) -> [RemotePushPlanner.Action]`;
    - `Action` is `.attention(Key, status:)` or `.clear(Key)`.
    - Only `"awaitingPermission"` and `"awaitingInput"` count as waiting.
    - A key missing from `statuses` counts as not waiting.
    - A move from `awaitingPermission` to `awaitingInput` is a new attention push.

- [ ] **Step 1: Write the failing tests.** Use `@Test(arguments:)` where the inputs are only variants.
  - Waits already present at `init` produce no action.
  - Idle → awaitingPermission → attention.
  - The same status again → nothing.
  - awaitingPermission → streaming → clear.
  - awaitingPermission → awaitingInput → attention with the new status.
  - A waiting session that disappears → clear.
  - `collapseId` is 32 characters of base64url, deterministic, and differs across server IDs for the same session ID.
- [ ] **Step 2: Run the tests.** Expect failures.
- [ ] **Step 3: Implement `RemotePushPlanner` and `RemotePushID`.**
- [ ] **Step 4: Implement `RemotePushNotifier`** (`@MainActor`).
  - It subscribes to `AlasHost` events. It keeps a status map seeded from the host snapshot's session summaries: `streamingState` mapped through `RemoteSessionGateway.stateString`. It updates the map on `.sessionChanged` and `.sessionRemoved`.
  - It merges in the federation provider's peer rows, keyed by each row's origin `serverId` and origin session ID. Use the `RemoteFederatedSessionID` decomposition.
  - Local rows are keyed by the host's own `serverId` and the session ID the remote list shows.
  - For each action, it POSTs to `relay.url/push` for every entry in `pushRelays`.
    - Use an ephemeral `URLSession` with a 10 s timeout and no retries.
    - On `410`, call `setPushRelay(nil, for:)`.
    - Log other failures and drop them.
  - It does nothing when no device has a relay.
- [ ] **Step 5: Wire it into `RemoteServer`** so the Mac and `alas-host` both get it.
- [ ] **Step 6: Run the planner suite and the AlasCore tests.** They pass. Build the Mac app.
- [ ] **Step 7: Commit:** `feat(remote): push to paired phones when a session needs the owner`.

### Task 4: Shared storage between the app and its extension

**Files:**
- Create: `Mobile/AlasMobile.entitlements`, `Mobile/NotificationService.entitlements`.
- Modify:
  - `Config/AlasMobile-Debug.xcconfig` and `-Release.xcconfig`: the Global Constraints settings;
  - `Mobile/project.yml`: entitlements, Info keys `AlasPushRelayURL`, `AlasPushEnvironment` and `AlasAppGroup`, and `UIBackgroundModes: [remote-notification]`;
  - `Mobile/Sources/Hosts/HostStore.swift`;
  - `Mobile/Sources/Hosts/SessionListCache.swift`: it stays in the app's Caches, unchanged unless it reads `HostStore` paths.

**Interfaces:**
- Produces:
  - `HostStore` reads and writes `hosts.json` in the app group container.
  - Keychain items go in the shared access group.
  - `HostStore.migrateIfNeeded()` runs once from `HostHub.init`:
    - it moves an old Application Support `hosts.json` into the group;
    - it moves each host's Keychain item from the default group to the shared one;
    - an item it can't read stays where it is, and the host then reads as unauthorized.
  - `enum AppGroup { static let id: String; static var containerURL: URL }`, read from Info.plist.

- [ ] **Step 1: Add the entitlements:**
  - `aps-environment: $(ALAS_APS_ENVIRONMENT)` (app only);
  - `com.apple.security.application-groups: [$(ALAS_APP_GROUP)]`;
  - `keychain-access-groups: [$(AppIdentifierPrefix)<app bundle id>.shared]`.
- [ ] **Step 2: Move `HostStore` and add the migration.** Regenerate with `cd Mobile && xcodegen`.
- [ ] **Step 3: Check in the simulator.**
  - Install main's build and pair the test host.
  - Install this build: the host is still paired and connects. That proves the migration.
- [ ] **Step 4: Build.** Run `xcodebuild … -destination 'generic/platform=iOS Simulator' build`.
- [ ] **Step 5: Commit:** `feat(ios): share paired hosts with app extensions`.

### Task 5: Register, route taps and clear alerts

**Files:**
- Create: `Mobile/Sources/Push/PushRegistrar.swift`, `Mobile/Sources/Push/AppDelegate.swift`.
- Modify:
  - `Mobile/Sources/App/AlasMobileApp.swift`: `@UIApplicationDelegateAdaptor`, and an app-level `openRoute`;
  - `Mobile/Sources/Hosts/HostHub.swift`: keep each host's hello capabilities; send `pushRegistration` on `.online`; send the unregister in `forget`;
  - `Mobile/Sources/Inbox/InboxView.swift`: take a `Binding<SessionRoute?>` that pushes the route.

**Interfaces:**
- Consumes: `"push.relay.v1"` and `pushRegistration` from Task 2; `RemotePushID.collapseId` from Task 3.
- Produces:
  - `@MainActor @Observable final class PushRegistrar` with:
    - `relayToken: String?`, persisted in the app group's `UserDefaults`;
    - `func start()`;
    - `func didRegister(deviceToken: Data)`.
  - `HostHub.registrar: PushRegistrar?`. The hub reads `relayToken` and sends to each online host whose hello advertised the capability. It sends again whenever the token changes.

- [ ] **Step 1: Write `PushRegistrar`.**
  - `start()` does nothing when `AlasPushRelayURL` is empty, or when no host is paired.
  - Otherwise it requests `.alert`, `.sound` and `.badge` authorization, and then `registerForRemoteNotifications()`. Call it again after pairing a host, so the prompt appears at first pairing rather than at first launch.
  - `didRegister` posts `/register` with the hex token, the bundle ID and `AlasPushEnvironment`. It stores the relay token, and keeps the old one when the request fails.
  - Register the categories here:
    - `"attention"`, with no actions;
    - `"permission"`, with actions `"allow"` (title "Allow", `.authenticationRequired`) and `"deny"` (title "Deny", `[.destructive, .authenticationRequired]`).
- [ ] **Step 2: Write `AppDelegate`.** It is the `UNUserNotificationCenterDelegate`.
  - Foreground presentation: `[.banner, .list, .sound]`.
  - Tap: decode `userInfo["alas"]` and find the host by `serverId`. Then switch to the Inbox tab and push `SessionRoute(hostID:, sessionId:)`.
    - For a federated session, the phone may know only the gateway. Find the host whose session list contains the namespaced `RemoteFederatedSessionID.compose(serverId:sessionId:)`.
    - If no host matches, just open the Inbox.
  - `didReceiveRemoteNotification` with `alas.clear == true`: remove the delivered notification whose identifier is `RemotePushID.collapseId(...)`, then complete with `.noData`.
- [ ] **Step 3: Reconcile on foreground.** Once session lists arrive after `connectAll()`, remove delivered notifications whose session is no longer waiting. This catches clear pings iOS never delivered.
- [ ] **Step 4: Build.** Smoke-test in the simulator with `xcrun simctl push <udid> io.nlopez.alas.dev <file>`:
  - an attention payload shows the alert, and tapping it opens the session;
  - a clear payload removes it.
- [ ] **Step 5: Commit:** `feat(ios): register for push and open the session from an alert`.

### Task 6: The notification service extension

**Files:**
- Create:
  - `Mobile/NotificationService/NotificationService.swift`;
  - `Packages/AlasCore/Sources/AlasRemoteKit/Push/RemotePushAlert.swift`;
  - a test suite for it in `AlasCoreTests`.
- Modify: `Mobile/project.yml`.
  - Add the target `AlasNotificationService`, type `app-extension`, embedded in the app.
  - Its sources are `NotificationService/` plus `Sources/Hosts/HostStore.swift` and `Sources/Hosts/PhoneProtocol.swift`.
  - It depends on `AlasRemoteKit`.

**Interfaces:**
- Consumes: the shared `HostStore` from Task 4.
- Produces:
  - `public enum RemotePushAlert`, with `public static func content(for message: RemoteServerMessageOf<some, some>, sessionTitle: String?) -> (title: String, body: String, isPermission: Bool)?`.
    - It returns nil for messages that aren't requests.
  - Its wording comes from the request wording the phone's `RequestCard` already uses:
    - a permission shows the tool title (`"Wants to run <title>"`), or `"Has a visual for you"` for a visual aid;
    - a question shows its first question's text;
    - a plan shows `"Plan ready for review"`;
    - an elicitation shows its message.
  - The title is the session title, or `"Alas"`. The body is truncated to 178 characters with `…`.
  - `isPermission` is true only for a permission that is not a visual aid.

- [ ] **Step 1: Write the failing tests.** Use one parameterized test over the request kinds:
  - a permission;
  - a permission for a visual aid;
  - a question;
  - a plan;
  - an elicitation;
  - a non-request message, which returns nil.

  Add one test for truncation at 178 characters.
- [ ] **Step 2: Run the tests.** Expect failures. Implement `RemotePushAlert`. Run them again: they pass.
- [ ] **Step 3: Write the extension.** In `didReceive`:
  - Decode `alas` and find the host by `serverId`; for a federated session, use the gateway rule from Task 5.
  - Open a `PhoneConnection` with that host's token.
  - On `.online`, send `listSessions` and `subscribe(sessionId)`.
  - Take the first request message for the session, plus the session's title from the list.
  - Set the title and body. Use category `"permission"` when `isPermission` is true, and keep `"attention"` otherwise.
  - Disconnect, then deliver.

  A 20 s deadline, or `serviceExtensionTimeWillExpire`, delivers the content as it arrived.
- [ ] **Step 4: Regenerate and build.** In the simulator, send a `mutable-content` payload with `simctl push` while the test host has a pending permission. The alert reads `"Wants to run …"`.
- [ ] **Step 5: Commit:** `feat(ios): show what a session is waiting on in its alert`.

### Task 7: Allow and Deny from the alert

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Push/RemotePermissionQuickAnswer.swift`, with its test.
- Modify:
  - `Mobile/Sources/Push/AppDelegate.swift`: the action handler;
  - `Mobile/Sources/Transcript/TranscriptSession.swift`: only if a completion hook is missing (see Step 3).

**Interfaces:**
- Produces: `public enum RemotePermissionQuickAnswer { public static func optionId(in payload: RemotePermissionPayload, allow: Bool) -> String? }`.
  - For Allow, it picks the first option of kind `allow_once`, falling back to `allow_always`.
  - For Deny, it picks the first `reject_once`, falling back to `reject_always`.
  - It returns nil when there is no match, which never guesses.

- [ ] **Step 1: Write the failing tests.** One parameterized test covering:
  - each kind preference and fallback;
  - no match gives nil.
- [ ] **Step 2: Implement `RemotePermissionQuickAnswer`.** Run the tests: they pass.
- [ ] **Step 3: Write the action handler.** It is `async` in `didReceive response`:
  - Acquire the session from the `SessionRegistry` and wait, with a 25 s deadline, until `state.pendingPermission` is present.
  - Pick the option, then call the existing permission answer, which takes over first when needed.
  - Wait until the request resolves, or the deadline passes, then return.
  - If no option matched, or the deadline passed first, post a local notification: "Couldn't answer. Open Alas to respond." Use the same session route in its `userInfo`.
  - If `TranscriptSession` exposes no way to observe that the answer settled, add the smallest such hook there.
- [ ] **Step 4: Smoke-test in the simulator.** A permission pending on the test host, with the Mac-side test client as writer:
  - pressing Allow on the alert answers it once;
  - the agent continues;
  - the alert clears.
- [ ] **Step 5: Commit:** `feat(ios): allow or deny a permission from its alert`.

### Task 8: Real delivery (owner and controller together)

You can't run this task in the simulator. It needs the owner's Apple and Cloudflare accounts.

- [ ] **Owner:**
  - Create an APNs Auth Key in the Apple Developer account, under Keys, with Apple Push Notifications service.
  - Enable push and app groups for `io.nlopez.alas` and `io.nlopez.alas.dev`; automatic signing does this once a team is set.
  - Deploy `relay/` as its README describes.
  - Set `DEVELOPMENT_TEAM` in `Config/AlasMobile-Local.xcconfig`.
- [ ] **Controller:** Commit the deployed URL as the default `ALAS_PUSH_RELAY_URL` in both xcconfigs. Then build to a real phone paired with a test host (not the owner's running Alas), and verify:
  - a real attention push arrives and is rewritten;
  - tapping it opens the session;
  - answering on the host clears the alert;
  - Allow works from the lock screen.
- [ ] **Commit:** `feat(ios): point push at the deployed relay`.
