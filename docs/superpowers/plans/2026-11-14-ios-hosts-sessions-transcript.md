# iOS Hosts, Session List and Live Transcript Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The iOS app pairs with Macs and `alas-host`s, keeps a connection to each, lists their sessions grouped by repo and worktree, and opens a session's live transcript with older-history paging. This is plan 3a of the parity work.

**Architecture:** UI-free client logic goes into `AlasRemoteKit`, so `swift test --package-path Packages/AlasCore` pins it on the Mac and the app needs no test target. That logic is:
- the pairing-link parser;
- the transcript sync state machine, moved from the Mac's `NativePeerTranscript`;
- a pairing client;
- the session directory (grouping, filters, search).

The app owns everything that touches the platform: the host store (a JSON file plus the Keychain), one `RemotePeerConnectionOf<OpaqueHostMessage, OpaqueHostMessage>` per host, and the screens. The transcript renders on the spike's candidate A (`UICollectionView` + `UIHostingConfiguration`), which this plan promotes out of `Spike/`.

**Tech Stack:** Swift 6, SwiftUI/UIKit on iOS 26, `AlasRemoteKit`, Security (Keychain), VisionKit (QR scanning), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-11-native-ios-app-design.md` (Goals, "Platform and code sharing", "Connectivity and hosts", "Performance bar", "Design")

## Plan 3 split

The spec's parity list is too large for one plan:
- **3a (this plan):** hosts and pairing, the connection, the session list, and the read-only live transcript.
- **3b:** composer (`/` commands, `@` mentions, images, stop, steer, usage), the prompt queue, take over, permission, question, plan and elicitation requests with the Inbox tab, session config, and rename.
- **3c:** Changes and Files tabs, new session and new worktree, visual aids, and a session-list cache for cold start.

Pairing with an Ed25519 key (`mobileApp` kind) stays with push in plan 4. 3a pairs as the web client does, which yields a `browser`-kind bearer token. It also pins the host's identity key when the pairing reply carries one.

## Global Constraints

- `AlasRemoteKit` imports only Foundation, CryptoKit and Observation (CLAUDE.md). The Mac app and `alas-host` keep working unchanged, and so does the web client. There is no wire change; `RemoteProtocolVersion` stays 1.
- The iOS app may import `AlasRemoteKit`, `Markdown`, SwiftUI, UIKit, Foundation, Security and VisionKit.
- The app's protocol instantiation is `RemoteClientMessageOf<OpaqueHostMessage, OpaqueHostMessage>`, `RemoteServerMessageOf<OpaqueHostMessage, OpaqueHostMessage>` and `RemotePeerConnectionOf<OpaqueHostMessage, OpaqueHostMessage>`. Define these app-local typealiases once in `Mobile/Sources/Hosts/PhoneProtocol.swift`: `PhoneClientMessage`, `PhoneServerMessage` and `PhoneConnection`.
- Pairing is `POST {origin}/pair` with JSON body `{"code": …, "deviceName": …}`. The WebSocket is `ws(s)://…/ws`, with the token as its subprotocol; `RemotePeerConnection` already does this.
- Older pages ask for `limit: 90`, as the web client's `OLDER_PAGE_SIZE` and the host's `RemoteTranscriptSync.tailWindow` do.
- The design is a guide, not a spec:
  - Glass goes only on floating controls (the system tab bar, toolbars, search). Lists and the transcript are flat.
  - Tabs are Worktrees, Inbox and Peers, plus search. In 3a, Inbox is an empty state that says requests arrive in a later build.
  - Reference: `design/alas-ios/reference/alas-ios-glass.html`.
- Info keys in `Mobile/project.yml`:
  - `NSAppTransportSecurity: {NSAllowsArbitraryLoads: true}`, because hosts are the user's own machines over plain HTTP on LAN and tailnet names;
  - `NSLocalNetworkUsageDescription: "Alas connects to your Macs on this network."`;
  - `NSCameraUsageDescription: "Scan a pairing code from your Mac."`.
- Tests use Swift Testing in `Packages/AlasCore/Tests/AlasCoreTests`, following the AGENTS.md testing policy. Moves need no new tests.
- After editing `Mobile/project.yml`, run `cd Mobile && xcodegen` and commit both.
- Conventional Commits (`feat(ios): …`, `refactor(remote): …`), with no agent attribution.
- Never pair the simulator with the owner's running Alas.app. Smoke tests use a local `alas-host` with an isolated `ALAS_APP_SUPPORT_DIR` (Task 4).

## Review Focus

1. **A host is unreachable on its last-used origin but reachable on another.** The app must connect via the other origin without user action. `RemotePeerConnection` already tries `lastOrigin` first and then the rest; Task 4 must pass every stored origin and persist `originChanged`.
2. **A delta arrives with a gap in revision or epoch** (after the phone slept, or the host restarted). The transcript must resubscribe and show the fresh snapshot, never a silently wrong row list. `RemoteTranscriptState.apply` returns `true`; Task 6 must act on it. This is pinned by the existing `NativePeerTranscriptTests`.
3. **The pairing code is wrong or expired.** Pairing must stop at the first `401` and say so, instead of burning the host's 5-per-minute redemption budget on every origin (Task 2 pins it).
4. **The app goes to background and back.** Connections close in the background and reconnect on foreground. Session lists and an open transcript stay on screen while that happens, with no blanking or "loading" flash (Task 4 owns the lifecycle; Task 6 resubscribes).
5. **A gateway Mac re-exports a peer's sessions** (`id` is `serverId:sessionId`, with `serverName` set). Those sessions must list under their origin host's name and open like any other (Task 3 pins the grouping).

---

### Task 1: Move the pairing-link parser and the transcript state into `AlasRemoteKit`

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasRemoteKit/RemotePairingLink.swift`. It receives `RemotePairingLinkParts` and `RemotePairingLink.parse(_:)`, moved byte-for-byte from `AlasHostCore/Remote/Pairing/RemotePairingLink.swift`. `build` and `encodeOrigin` stay in HostCore as an extension.
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Client/RemoteTranscriptState.swift`, moved from `Alas/Sources/Remote/Native/NativePeerTranscript.swift`.
- Modify: `Alas/Sources/Remote/Native/NativePeerTranscript.swift`. It becomes `typealias NativePeerTranscript = RemoteTranscriptState<HostServerMessage, HostClientMessage>` plus an extension holding `applyOptimistic(_ spec: ChipSpec, itemId: String)`.

**Interfaces:**
- Produces:
  - `public struct RemoteTranscriptState<ServerHost: Codable & Equatable & Sendable, ClientHost: Codable & Equatable & Sendable>: Equatable`. Use whatever constraints `RemoteServerMessageOf` requires. Every member keeps its current name and meaning and becomes `public`:
    - `apply(_: RemoteServerMessageOf<ServerHost, ClientHost>) -> Bool`
    - `messages`, `messagesGeneration`, `firstIndex`, `totalCount`, `epoch`, `revision`, `streamingState`, `canDrive`, `olderPageBeforeIndex`, `needsResubscribe`, `resetResubscribeRequest()`, `markUnavailable()`
    - the pending-request fields, `requestGeneration(for:)`, `PendingRequestKind`, `config`, `queue`
    - `applyOptimistic(configId:value:)`, `applyOptimisticAutoRun(_:)`
  - The ChipSpec overload needs to set `config`. Add `public mutating func updateConfig(_ transform: (inout RemoteSessionConfig) -> Void)`, which does nothing when `config` is nil, and build the Mac extension on it.
  - `RemotePairingLink.parse(_ text: String) -> RemotePairingLinkParts?` is public in the Kit.

- [ ] **Step 1: Move both pieces as described.** Fix imports wherever the compiler asks. No Mac call site changes beyond the typealias.
- [ ] **Step 2: Build the Kit for iOS.** Run `cd Packages/AlasCore && xcodebuild -scheme AlasRemoteKit -destination 'generic/platform=iOS Simulator' -quiet build > /tmp/kit-ios.log 2>&1; echo $?`. Expected: `0`.
- [ ] **Step 3: Run the core tests.** Run `swift test --package-path Packages/AlasCore > /tmp/core.log 2>&1; echo $?`. Expected: `0`.
- [ ] **Step 4: Run the Mac suites that pin the moved code.** Use the CLAUDE.md `xcodebuild … -only-testing` command with `AlasTests/NativePeerTranscriptTests`, `AlasTests/RemotePairingLinkTests` and `AlasTests/NativePeerSessionsTests`. Expected: every `✔` line, no `✘`. The run needs `CARGO_PROFILE_RELEASE_STRIP=false` and Ghostty built (`scripts/build-ghostty.sh`).
- [ ] **Step 5: Commit** as `refactor(remote): move transcript sync and pairing-link parsing into AlasRemoteKit`.

### Task 2: Pairing client

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Client/RemotePairingClient.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/RemotePairingClientTests.swift`

**Interfaces:**
- Produces:
  - `public struct RemotePairingResult: Equatable, Sendable { public let origin: String; public let token: String; public let serverId: String?; public let name: String?; public let publicKey: String? }`
  - `public enum RemotePairingError: Error, Equatable { case codeRejected; case originNotAllowed; case unreachable }`
  - `public struct RemotePairingClient: Sendable` with:
    - `public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)`
    - `public init(transport: @escaping Transport = RemotePairingClient.urlSession(timeout: 4))`
    - `public func pair(origins: [String], code: String, deviceName: String) async throws(RemotePairingError) -> RemotePairingResult`

- [ ] **Step 1: Write the failing tests.** A fake transport answers per origin. Each test does one thing:
  - `pairsWithTheFirstOriginThatAnswers`: origin 1 throws `URLError(.timedOut)`; origin 2 returns 200 `{"token":"t","serverId":"s","name":"Mac","publicKey":"k"}`. Expect a result with `origin == origin2`, `token == "t"` and `publicKey == "k"`.
  - `stopsAtTheFirstRejectedCode`: origin 1 returns 401. Expect `.codeRejected`, and origin 2 is never requested. This protects the host's redemption budget.
  - `triesTheNextOriginWhenOneIsNotAllowed`: origin 1 returns 403 and origin 2 returns 200. Expect success. With 403 only, expect `.originNotAllowed`.
  - `skipsLoopbackOrigins`: `http://127.0.0.1:1`, `http://localhost:1` and `http://[::1]:1` are never requested. On a phone they are the phone itself.
  - `sendsCodeAndDeviceNameAsJSON`: the request is `POST {origin}/pair` and its body decodes to `{"code","deviceName"}`.

  When every origin fails without a 401 or 403, the result is `.unreachable`.
- [ ] **Step 2: Run them.** Run `swift test --package-path Packages/AlasCore --filter RemotePairingClientTests`. Expected: they fail to compile.
- [ ] **Step 3: Implement `RemotePairingClient`.** Try origins in order, skipping loopback hosts. 401 throws `.codeRejected` at once; 403 moves to the next origin and remembers it. Decode the reply with `JSONDecoder`. `urlSession(timeout:)` is the default transport, using `URLSession` with that request timeout.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit** as `feat(remote): add a pairing client for native apps`.

### Task 3: Session directory

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Client/RemoteSessionDirectory.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/RemoteSessionDirectoryTests.swift`

**Interfaces:**
- Produces, ported from `Alas/Resources/RemoteWeb/repo-filter.js`, whose semantics are binding:
  - `public enum RemoteSessionFilter: CaseIterable, Sendable { case all, running, dirty }`
  - `public struct RemoteWorktreeEntry: Identifiable, Equatable, Sendable { public let id: String; public let title: String; public let summary: RemoteWorktreeSummary?; public let activeSessions: [RemoteSessionSummary]; public let closedSessions: [RemoteSessionSummary]; public var isRunning: Bool; public var isDirty: Bool; public var needsAttention: Bool }`
  - `public struct RemoteRepoSection: Identifiable, Equatable, Sendable { public let id: String; public let title: String; public let hostName: String?; public let worktrees: [RemoteWorktreeEntry] }`
  - `public enum RemoteSessionDirectory` with:
    - `public static func sections(_ sessions: [RemoteSessionSummary], localHostName: String) -> [RemoteRepoSection]`
    - `public static func filter(_ sections: [RemoteRepoSection], by filter: RemoteSessionFilter, query: String) -> [RemoteRepoSection]`
    - `public static func counts(_ sections: [RemoteRepoSection]) -> [RemoteSessionFilter: Int]`
  - Rules:
    - Sections key on `serverId` (nil for local) plus `projectId ?? worktree.projectName ?? "Other"`. `hostName` is `serverName` for federated rows and nil for local ones.
    - Worktrees key on `worktreeId ?? worktree.path ?? session.id`.
    - `isActive == false` sessions go to `closedSessions`.
    - Running: an active session whose status is not `"idle"`.
    - Dirty: `summary.changedFileCount > 0`.
    - Attention: an active session whose status is `awaitingPermission` or `awaitingInput`.
    - Sort sections by most recent `updatedAt`, then title; worktrees likewise.
    - The query matches, case-insensitively, the section title, the worktree title, the branch, or any session title.

- [ ] **Step 1: Write the failing tests.**
  - `groupsByRepoThenWorktree`: parameterized over the worktree key fallback (worktreeId, then path, then session id).
  - `federatedSessionsGroupUnderTheirHost`.
  - `closedSessionsAreSeparated`.
  - `filtersMatchTheWebClient`: parameterized over running, dirty and attention.
  - `queryMatchesRepoWorktreeBranchOrSessionTitle`: parameterized.
  - `countsPerFilter`.
- [ ] **Step 2: Run them.** Run `swift test --package-path Packages/AlasCore --filter RemoteSessionDirectoryTests`. Expected: they fail to compile.
- [ ] **Step 3: Implement it** to the rules above.
- [ ] **Step 4: Run the tests.** Expected: all pass.
- [ ] **Step 5: Commit** as `feat(remote): group remote sessions by repo and worktree for native clients`.

### Task 4: Hosts, pairing UI and connection lifecycle

**Files:**
- Create: `Mobile/Sources/Hosts/PhoneProtocol.swift` (the typealiases)
- Create: `Mobile/Sources/Hosts/HostStore.swift`. It persists `[PairedHost]` as JSON in Application Support. Each token is a Keychain generic password with service `io.nlopez.alas.remote` and account `host.<id>`.
- Create: `Mobile/Sources/Hosts/HostHub.swift`
- Create: `Mobile/Sources/Hosts/PeersView.swift`, `Mobile/Sources/Hosts/PairHostView.swift`
- Modify: `Mobile/Sources/App/AlasMobileApp.swift`. Root is a `TabView` with Worktrees (a placeholder until Task 5), Inbox (empty state) and Peers. Search is the system `Tab(role: .search)`. The spike moves behind a "Transcript benchmark" row at the bottom of Peers, in DEBUG builds only.
- Modify: `Mobile/project.yml` (the Info keys from Global Constraints), then regenerate.

**Interfaces:**
- Consumes: `RemotePairingClient` (Task 2), `RemotePairingLink.parse` (Task 1).
- Produces:
  - `struct PairedHost: Codable, Identifiable, Equatable { let id: UUID; var name: String; var serverId: String?; var origins: [String]; var lastOrigin: String?; var publicKey: String?; let addedAt: Date }`
  - `@MainActor @Observable final class HostHub`, with:
    - `private(set) var hosts: [PairedHost]`
    - `func state(of id: UUID) -> PhoneConnection.State`
    - `func sessions(of id: UUID) -> [RemoteSessionSummary]`
    - `func pair(origins: [String], code: String) async throws(RemotePairingError)`
    - `func forget(_ id: UUID)`
    - `func connectAll()`
    - `func disconnectAll()`
    - `func send(_ message: PhoneClientMessage, to id: UUID)`
    - `func addListener(_ id: UUID, _ handler: @escaping @MainActor (PhoneServerMessage) -> Void) -> ListenerToken`. A token's `cancel()` removes the listener. Task 6 uses this to see a host's transcript frames.

- [ ] **Step 1: Write `HostStore` and `HostHub`.**
  - Each host gets one `PhoneConnection`, built with `origins`, `lastOrigin`, the Keychain token, `expectedServerId: serverId` and `expectedPublicKey: publicKey`, so the host's identity is pinned when pairing returned a key.
  - `.originChanged` persists `lastOrigin`.
  - `.hello` and `.stateChanged(.online)` send `.listSessions`. `.sessionList` replaces that host's sessions. Every `.message` also goes to the host's listeners.
  - `pair` uses device name `"Alas for iOS"` and then connects the new host.
  - The app's `scenePhase` drives the lifecycle: `.active` calls `connectAll()`, `.background` calls `disconnectAll()`. Sessions stay in memory across both, so lists never blank.
- [ ] **Step 2: Write `PairHostView`, a sheet with three ways in.**
  - Paste a pairing link, parsed with `RemotePairingLink.parse`.
  - Address plus code, normalized with `RemotePairingLink.normalizeOrigin`.
  - Scan a QR code with VisionKit `DataScannerViewController` (barcode `.qr`), shown only when `DataScannerViewController.isSupported`. It feeds the scanned text into the link path.

  Errors read:
  - `.codeRejected`: "That code was wrong or has expired. Make a new one on your Mac."
  - `.originNotAllowed`: "This Mac doesn't accept connections from this address."
  - `.unreachable`: "Couldn't reach your Mac. Check that you're on the same network or tailnet."
- [ ] **Step 3: Write `PeersView`.** It lists hosts with their name, connection state and current origin, swipe to forget, and a toolbar "+" that opens `PairHostView`. A host whose state is `unauthorized` shows a "Pair again" button that opens `PairHostView` with its origins prefilled.
- [ ] **Step 4: Regenerate the project and build** with the Plan 2 build command (generic iOS Simulator, `-disableAutomaticPackageResolution`). Expected: `0`.
- [ ] **Step 5: Smoke-test against a local `alas-host`.**
  - Build `alas-host` (`swift build --package-path Packages/AlasCore --product alas-host`).
  - Run it with `ALAS_APP_SUPPORT_DIR=/tmp/alas-ios-smoke/Alas`. Enable Remote through `alas-host config` (find the key with `config list`), start it, and run `alas-host pair`.
  - Pair the simulator app through "Address + code" with the printed loopback address.
  - Expect the host online in Peers. Then background and foreground the app (`xcrun simctl` home button / relaunch): the host reconnects.
  - Stop the host, and delete `/tmp/alas-ios-smoke` afterwards.
- [ ] **Step 6: Commit** as `feat(ios): pair with hosts and keep their connections`.

### Task 5: Worktrees tab

**Files:**
- Create: `Mobile/Sources/Sessions/WorktreesView.swift`, `Mobile/Sources/Sessions/WorktreeRow.swift`
- Modify: `Mobile/Sources/App/AlasMobileApp.swift`, so the Worktrees tab and the search tab show `WorktreesView`

**Interfaces:**
- Consumes: `HostHub.sessions(of:)` and `hosts` (Task 4), and `RemoteSessionDirectory` (Task 3).
- Produces: `WorktreesView(hub: HostHub)`. Tapping a session pushes `TranscriptScreen(hub:hostID:session:)`, which Task 6 creates. Until then the destination is `Text(session.title)`.

- [ ] **Step 1: Write `WorktreesView`.**
  - It shows one list section per (host, repo) section from `RemoteSessionDirectory.sections(hub.sessions(of:), localHostName: host.name)`, across all hosts.
  - The section header shows the repo tile (initials, and a color hashed from the name as `repoTileColor` does) and the host name when there is more than one host or the section is federated.
  - A segmented All / Running / Dirty control with `counts`, and `.searchable` bound to the query.
  - Each worktree row shows the branch, a status line ("running", "N files", "N conflicts", "clean" or "changes unavailable", as `worktreeStatus` decides), +/− from the summary, an attention dot when `needsAttention`, and its active sessions as tappable sub-rows with relative time.
  - Empty states: no hosts ("Pair a Mac" button that switches to Peers) and no sessions.
- [ ] **Step 2: Build.** Expected: `0`.
- [ ] **Step 3: Smoke-test against the local `alas-host`** from Task 4, with one project added (`alas-host project add <a scratch git repo>`). The repo section appears. Screenshot it with `xcrun simctl io booted screenshot`.
- [ ] **Step 4: Commit** as `feat(ios): list sessions by repo and worktree`.

### Task 6: Live transcript

**Files:**
- Move: `Mobile/Sources/Spike/CollectionTranscriptView.swift` → `Mobile/Sources/Transcript/TranscriptCollectionView.swift`, generalized as below.
- Move: `Mobile/Sources/Spike/SpikeRowView.swift` and `MarkdownBlocks.swift` → `Mobile/Sources/Transcript/TranscriptRowView.swift` and `MarkdownBlocks.swift`.
- Modify: the `Spike/` files, adapting `SpikeScreen` to the generalized view so the benchmark keeps working.
- Create: `Mobile/Sources/Transcript/TranscriptSession.swift`, `Mobile/Sources/Transcript/TranscriptScreen.swift`
- Modify: `Mobile/Sources/Sessions/WorktreesView.swift`, so the destination is `TranscriptScreen`.

**Interfaces:**
- Consumes: `RemoteTranscriptState` (Task 1), and `HostHub.send` and `addListener` (Task 4).
- Produces:
  - `struct TranscriptItem: Identifiable, Equatable { let id: String; let row: RemoteTranscriptRow; let message: RemoteWireMessage }`. `id` is `stableId`. The collection view reconfigures an item when its `message` changes, which replaces the spike's `revision`.
  - `TranscriptCollectionView(items: [TranscriptItem], expanded: Binding<Set<String>>, canLoadOlder: Bool, loadOlder: @escaping () -> Void, onFirstLayout: @escaping () -> Void = {})`, with the spike's candidate A behavior kept: tail-follow, prepend anchoring, expand anchoring.
  - `@MainActor @Observable final class TranscriptSession`, with:
    - `init(hub: HostHub, hostID: UUID, sessionId: String)`
    - `private(set) var items: [TranscriptItem]`
    - `var expanded: Set<String>`
    - `var canLoadOlder: Bool`
    - `func open()`, which sends `.subscribe(sessionId:)` and registers its listener
    - `func close()`, which sends `.unsubscribe(sessionId:)` and cancels the listener
    - `func loadOlder()`
    - `func image(for path: String) -> UIImage?`

- [ ] **Step 1: Write `TranscriptSession`.**
  - It applies every frame for its `sessionId` to a `RemoteTranscriptState<OpaqueHostMessage, OpaqueHostMessage>`. When `apply` returns `true`, it calls `resetResubscribeRequest()` and sends `.subscribe` again.
  - It rebuilds `items` only when `messagesGeneration` changes, mapping messages through `RemoteTranscriptRow(message:)`.
  - `loadOlder` sends `.fetchOlder(sessionId:, beforeIndex: olderPageBeforeIndex, limit: 90)` once per page and clears the in-flight flag on `transcriptPage` or `transcriptSnapshot`, as `NativePeerSessions.receive` does.
  - When the host comes back online, it resubscribes.
  - Images: the user rows' `images[].uri` are requested with `.readTranscriptImage` on first display, and `transcriptImage` results are cached by path. A nil `data` result marks the image unavailable.
- [ ] **Step 2: Generalize and move the collection view and the row view** as listed.
  - The row view shows user images as thumbnails, and the label stays until the bytes arrive.
  - `RemoteTranscriptRow(message:)` turns unknown kinds, `failureIncident` among them, into `.systemNotice(text)`. Keep that in 3a; a dedicated failure card belongs with the request cards in 3b.
- [ ] **Step 3: Write `TranscriptScreen`.**
  - The navigation title is the session title, with a subtitle showing the branch and streaming state.
  - The transcript is flat and uses the system background.
  - `open()` runs on appear and `close()` on disappear.
  - A session the host reports closed (`sessionClosed`) shows a footer: "This session has ended."
- [ ] **Step 4: Build.** Expected: `0`. Then check that the spike benchmark still opens.
- [ ] **Step 5: Smoke-test against the local `alas-host`.** If an ACP agent is available to the host (`alas-host registry search` / `install`), start a session from the host and open it on the phone: rows appear, streaming follows the tail, and scrolling up pages in older rows. If no agent can run there, check that open, subscribe and the empty state work, and record that streaming was not exercised.
- [ ] **Step 6: Commit** as `feat(ios): open a session's live transcript`.

---

## Not in this plan

- Everything in 3b and 3c above, and push and key pairing (plan 4).
- A disk cache of session lists for cold start (3c).
- iPad layout.
