# `alas-host` setup and command-line configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Mac that runs only `alas-host` be set up and reconfigured from a terminal: a rerunnable full-screen `alas-host setup`, `config get|set|list`, `project add|remove|list`, `restart`, LAN reachability, and the host honoring every setting it exposes.

**Architecture:** A host-only `AppConfig.host` section holds reachability and port, with a pure resolver that falls back to today's shared Remote keys. A table of configurable settings (`HostSetting`) in `AlasHostCore` parses, validates, reads and writes each setting on an `AppConfig`; `config`, `setup` and docs all use it. Profile writes go through one gate that knows who holds the data directory (nobody, a host, the app). Project commands use the running host's socket, or boot an in-process host when none runs. The terminal UI is a small hand-written layer in the `alas-host` target over a testable `HostSetupModel` in `AlasHostCore`.

**Tech Stack:** Swift 6, SwiftPM package `Packages/AlasCore` (targets `AlasModel`, `AlasHostCore`, executable `alas-host`), Swift Testing, termios + ANSI escapes, `launchctl`.

**Spec:** `docs/superpowers/specs/2026-10-21-alas-host-setup-design.md`

## Global Constraints

- No SwiftUI, AppKit, or new third-party dependency; the terminal UI is raw mode + ANSI escapes in Swift (`AGENTS.md`, spec anti-goals).
- No setting is exposed unless the host honors it. Exposing the Alas MCP server is out of scope.
- Reachability and port are host-only: the app never reads `AppConfig.host`. Absent, the host derives them from `remote.enabled`, `remote.port`, `remote.tailscaleServe` exactly as today. Loopback stays the default; LAN is only ever an explicit choice.
- Bonjour (`remote.discoverable`) stays off on the host.
- When the app holds the data directory, `setup`, `config set`, `project add|remove` refuse with a message; `config get|list` and `project list` still work.
- Everything honors `ALAS_APP_SUPPORT_DIR`.
- Tests: Swift Testing, extend existing suites, no fixed sleeps, parameterize variants (`AGENTS.md` testing policy). Run `swift test --package-path Packages/AlasCore` before every commit; touch `Packages/AlasCore/Sources/alas-host/main.swift` first when the executable tests run after an `AppConfig` change (a stale incremental `alas-host` reads the old layout).
- Conventional Commits; no agent attribution.

## Review Focus

1. `app.json` written by an older app (no `host` key, unknown keys, bad values) must still decode, and `config set` must not reset settings it does not touch. → Task 1 test `hostSectionAbsentKeepsSharedRemoteBehavior`, Task 4 test `writeKeepsUntouchedSettings`.
2. A host upgraded with `remote.enabled = true` and no `host` section must keep serving loopback only, never LAN. → Task 1 parameterized test `resolvesReachability`.
3. `config set` with a wrong value (`host.port 70000`, `harness.acpAutoRunByDefault maybe`, unknown key, unknown agent id) must fail with a message naming the valid values and change nothing. → Task 3 test `rejectsInvalidValues`.
4. Running `config set` or `project add` while the app is open must refuse, not write a file the app will overwrite. → Task 4 test `classifiesHolder`.
5. Removing a project whose worktree has a live session or run must refuse instead of orphaning it. → Task 5 test `removeProjectRefusesWhileWorkIsLive`.

---

### Task 1: Host-only reachability settings

**Files:**
- Create: `Packages/AlasCore/Sources/AlasModel/Persistence/HostSettings.swift`
- Modify: `Packages/AlasCore/Sources/AlasModel/Persistence/AppConfig.swift` (property, `CodingKeys`, lenient `init(from:)`, memberwise/`defaults` if needed)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/AppConfigDecodingTests.swift`

**Interfaces:**
- Produces:
  - `public enum HostReachability: String, Codable, CaseIterable, Sendable { case off, loopback, lan, tailscale }`
  - `public struct HostSettings: Codable, Equatable, Sendable { public var reachability: HostReachability?; public var port: UInt16? }` (both nil = derive)
  - `AppConfig.host: HostSettings` (decoded leniently, default `.init()`)
  - `public struct HostRemoteListen: Equatable, Sendable { public var port: UInt16; public var loopbackOnly: Bool; public var tailscaleServe: Bool }`
  - `extension AppConfig { public var hostReachability: HostReachability; public var hostPort: UInt16; public var hostRemoteListen: HostRemoteListen? }` — `hostReachability` is `host.reachability ?? (remote.enabled ? (remote.tailscaleServe ? .tailscale : .loopback) : .off)`; `hostPort` is `host.port ?? remote.preferredPort`; `hostRemoteListen` is nil for `.off`, `loopbackOnly` true except `.lan`, `tailscaleServe` true only for `.tailscale`.

- [ ] **Step 1: Write the failing tests** in `AppConfigDecodingTests`:
  - `@Test(arguments:)` `resolvesReachability` over (`host.reachability`, `remote.enabled`, `remote.tailscaleServe`) → expected `hostRemoteListen`: (nil,false,false)→nil; (nil,true,false)→loopback; (nil,true,true)→tailscale (loopbackOnly true, serve true); (.lan,false,false)→loopbackOnly false; (.off,true,false)→nil; (.loopback,true,true)→loopback, no serve.
  - `hostSectionAbsentKeepsSharedRemoteBehavior`: decode `{"remote":{"enabled":true,"port":9000}}` → `host == .init()`, `hostPort == 9000`, `hostReachability == .loopback`.
  - `hostSectionRoundTrips`: encode then decode a config with `host = HostSettings(reachability: .lan, port: 18765)` preserves it; a bad `host.reachability` string decodes to nil without failing the file.
- [ ] **Step 2: Run** `swift test --package-path Packages/AlasCore --filter AppConfigDecodingTests` — Expected: FAIL (types not defined).
- [ ] **Step 3: Implement** the types and `AppConfig.host` (key `host`), following the file's lenient decoding pattern (`try? decodeIfPresent`).
- [ ] **Step 4: Run** the same command — Expected: PASS.
- [ ] **Step 5: Commit** `feat(host): add host-only reachability settings`

### Task 2: The host applies its settings

**Files:**
- Modify: `Packages/AlasCore/Sources/alas-host/main.swift` (Remote start, ~lines 180–265)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost+Boot.swift` (`boot`)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/AlasCoreContext.swift` (add a factory)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/AlasHostExecutableTests.swift`

**Interfaces:**
- Consumes: `AppConfig.hostRemoteListen` (Task 1).
- Produces: `AlasCoreContext.sessionManagerFactory(config: @escaping @MainActor () -> AppConfig) -> @MainActor (SessionOwnerID, Worktree) -> ACPSessionManager`, building the same manager as `defaultSessionManager` plus `autoResumeAfterUsageLimit: { config().harness.acpAutoResumeAfterUsageLimit }` and `continueInterruptedSessions: { config().harness.acpContinueInterruptedSessions }`.

- [ ] **Step 1: Write the failing test** in `AlasHostExecutableTests`: `aHostServesTheReachabilityItsSettingsName` — profile `app.json` with `host = {reachability: "loopback", port: <free port>}` and `remote.enabled = false`: the host prints `remote http://127.0.0.1:<port>`; a second profile with `host.reachability = "off"` and `remote.enabled = true` prints no `remote ` line within the time the first one took (await the socket line, then assert absence). Reuse `AlasHostProcess` and `eventually`.
- [ ] **Step 2: Run** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter AlasHostExecutableTests` — Expected: FAIL (host ignores `host`).
- [ ] **Step 3: Implement:**
  - `main.swift`: start Remote when `config.hostRemoteListen` is non-nil, with `server.start(port: listen.port, loopbackOnly: listen.loopbackOnly)`; run `tailscale serve` only when `listen.tailscaleServe`; keep `discoverable` off. Update the comment that says a command-line tool cannot serve the LAN: cite TN3179 (accepting incoming TCP needs no local network access; Bonjour does).
  - `boot`: pass `makeSessionManager: AlasCoreContext.sessionManagerFactory(config: { environment.config })`.
  - Check `worktrees.rootPath` and `worktrees.branchTemplate` reach the host's worktree creation through `environment.configuration()`; if either does not, wire it the same way and note it in the commit.
- [ ] **Step 4: Run** the Step 2 command, then the whole package — Expected: PASS.
- [ ] **Step 5: Commit** `feat(host): serve the configured reachability and honor session behavior settings`

### Task 3: The configurable settings table

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/Setup/HostSetting.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostSettingTests.swift` (new type, no existing suite)

**Interfaces:**
- Consumes: `HostSettings`, `HostReachability` (Task 1); `AgentConfiguredCatalog.all(builtinState:customs:)`.
- Produces:
  - `public struct HostSetting: Sendable { public let key: String; public let section: HostSettingSection; public let title: String; public let kind: HostSettingKind; public func value(in: AppConfig) -> String; public func set(_ value: String, in: inout AppConfig) throws(HostSettingError) }`
  - `public enum HostSettingSection: String, CaseIterable, Sendable { case reachability, agents, behavior, worktrees }`
  - `public enum HostSettingKind: Equatable, Sendable { case bool, port, text, path, choice([String]) }`
  - `public enum HostSettingError: Error, Equatable, LocalizedError { case unknownKey(String), invalidValue(key: String, expected: String) }`
  - `public enum HostSettingCatalog`: `public static func all(for config: AppConfig) -> [HostSetting]` and `public static func named(_ key: String, in config: AppConfig) throws(HostSettingError) -> HostSetting`.
- Keys, exactly: `host.reachability` (choice off|loopback|lan|tailscale), `host.port` (port 1–65535), `remote.displayName` (text), `agents.<id>.enabled` (bool; one per built-in and registry agent), `harness.acpAutoRunByDefault`, `harness.acpAutoResumeAfterUsageLimit`, `harness.acpContinueInterruptedSessions` (bool), `worktrees.rootPath` (path), `worktrees.baseBranch` (text), `worktrees.branchTemplate` (text; empty sets nil).
- Bool values accept `true|false|on|off|yes|no`; printed as `true|false`.

- [ ] **Step 1: Write the failing tests:**
  - `@Test(arguments:)` `setsAndReadsEachKey` over (key, input, printed): ("host.reachability","lan","lan"), ("host.port","18765","18765"), ("harness.acpAutoResumeAfterUsageLimit","off","false"), ("worktrees.branchTemplate","","") and asserts `value(in:)` after `set`.
  - `@Test(arguments:)` `rejectsInvalidValues` over ("host.port","70000"), ("host.port","0"), ("harness.acpAutoRunByDefault","maybe"), ("host.reachability","wan"), ("agents.nope.enabled","true"), ("theme","dark"): throws the matching `HostSettingError` and leaves the config `==` its original.
  - `listsOneEnabledSettingPerAgent`: with a config whose registry has one installed agent, `all(for:)` contains `agents.<builtin>.enabled` for every built-in and `agents.<registryID>.enabled`, and setting it flips `builtinState[id].isEnabled` / `registry[i].isEnabled`.
- [ ] **Step 2: Run** `swift test --package-path Packages/AlasCore --filter HostSettingTests` — Expected: FAIL.
- [ ] **Step 3: Implement** the table with a key-path-like closure pair per entry; `<id>` entries are generated from the catalog.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(host): describe the settings the host can configure`

### Task 4: Who holds the profile, and writing it

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/Setup/HostProfileAccess.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/DataDirectoryLockTests.swift` (holder classification) and `AppConfigDecodingTests.swift` (write merge)

**Interfaces:**
- Consumes: `DataDirectoryLock.acquire()` and `.Refusal.held(pid:)`; `HostSetting.set` (Task 3).
- Produces:
  - `public enum DataDirectoryHolder: Equatable, Sendable { case none(DataDirectoryLock), host(pid: Int32), app(pid: Int32?), unknown(pid: Int32?) }` (`none` carries the acquired lock; release by dropping it)
  - `public static func DataDirectoryHolder.current() -> DataDirectoryHolder` — acquire; on `.held(pid)`, classify by the pid's executable (`proc_pidpath`) through `classify(executableName:pid:)`.
  - `static func classify(executableName: String?, pid: Int32?) -> DataDirectoryHolder` — `"alas-host"` → `.host`, `"Alas"` → `.app`, otherwise `.unknown`.
  - `public enum HostProfileWrite { public static func update(_ change: (inout AppConfig) throws -> Void, file: URL = Paths.appConfigFile, store: PersistenceStore = .init()) throws }` — read (`.defaults` when absent), apply, write.
  - `public struct HostProfileRefusal: LocalizedError` with the copy: `"The Alas app has this profile open. Change settings in its Settings window, or quit it and run this again."`

- [ ] **Step 1: Write the failing tests:**
  - `@Test(arguments:)` `classifiesHolder` over ("alas-host",.host), ("Alas",.app), ("zsh",.unknown), (nil,.unknown).
  - `writeKeepsUntouchedSettings`: a file with `themeId = "x"`, `remote.enabled = true`, `terminal.fontSize = 17`; `update { try HostSettingCatalog.named("host.port", in: $0).set("9999", in: &$0) }` → re-read file has `host.port == 9999` and the three untouched values unchanged.
- [ ] **Step 2: Run** `swift test --package-path Packages/AlasCore --filter "DataDirectoryLockTests|AppConfigDecodingTests"` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(host): tell who holds a profile and update its settings`

### Task 5: Removing a project through the host

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocol.swift` (`HostRequest.removeProject(projectID: String)`, a refusal case if none fits)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Core/HostProtocolServer.swift` (dispatch)
- Modify: the `ProjectsAPI` in `Packages/AlasCore/Sources/AlasHostCore/Core/AlasHost.swift` (or its extension file) and `AlasCoreContext` (remove + persist, as `addProject` persists)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostProtocolServerTests.swift`

**Interfaces:**
- Produces: `ProjectsAPI.remove(projectID: String, caller: HostCaller) async throws` — refuses with `HostError` (`.projectBusy` or the closest existing case) while any of the project's worktrees has a live session manager runner or a process run; otherwise disposes its idle session managers, calls `ProjectsManager.removeProject(id:)`, persists `projects.json`, and emits the same event an add does.

- [ ] **Step 1: Write the failing tests** in `HostProtocolServerTests`:
  - `removeProjectForgetsIt`: add a project from a template repo (existing helper), send `.removeProject`, then `.snapshot` has no such project and `projects.json` on disk lists none.
  - `removeProjectRefusesWhileWorkIsLive`: with a session started in its worktree (existing scripted-agent fixture), `.removeProject` fails and the project remains.
  - Unknown id → the protocol's not-found failure.
- [ ] **Step 2: Run** `swift test --package-path Packages/AlasCore --filter HostProtocolServerTests` — Expected: FAIL.
- [ ] **Step 3: Implement**, keeping `HostProtocolVersion.current` at 1 (an added request is backward compatible; an older host answers `invalidRequest`, which the CLI reports as "the running host is older").
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `feat(host): remove projects through the host protocol`

### Task 6: `config`, `project` and `restart` commands

**Files:**
- Create: `Packages/AlasCore/Sources/alas-host/Commands.swift` (dispatch for the new subcommands; `main.swift` calls it before the serve path)
- Modify: `Packages/AlasCore/Sources/alas-host/main.swift` (usage text, dispatch)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/AlasHostExecutableTests.swift`

**Interfaces:**
- Consumes: Tasks 3–5; `HostSocketServer.request(_:)`; `HostLaunchAgent`.
- Command surface, exactly:
  - `alas-host config list` (also `config get` with no key): one `key = value` line per setting, grouped by section.
  - `alas-host config get <key>` prints the value.
  - `alas-host config set <key> <value> [--restart]` writes through `HostProfileWrite.update` after `DataDirectoryHolder.current()`: `.app` → refuse (exit 1, `HostProfileRefusal`); `.host` → write, then print `Saved. Restart the host to apply: alas-host restart` unless `--restart`; `.none`/`.unknown` → write.
  - `alas-host project list` prints `id  name  path`.
  - `alas-host project add <path> [--name <name>]` and `project remove <id|path>`: `.host` → socket request; `.none` → `AlasHost.boot()` in process while holding the acquired lock, perform, `await host.shutdown()`, exit; `.app` → refuse. `--name` defaults to the folder name; kind is `git` when the path is a git work tree, else `folder`.
  - `alas-host restart`: when the profile's `HostLaunchAgent` plist exists and `launchctl print gui/<uid>/<label>` succeeds → `launchctl kickstart -k gui/<uid>/<label>`, print `Restarted.`; when a host runs outside launchd → exit 1 with `The host is not running as a launch agent; stop it (Ctrl-C) and start it again.`; when none runs → `No host is running.`

- [ ] **Step 1: Write the failing test** `aProfileIsConfiguredFromTheCommandLine` in `AlasHostExecutableTests`, on a scratch profile with no host running: `config set host.port 18999` then `config get host.port` prints `18999`; `config set host.port 70000` exits 1 and the value stays; `project add <template repo>` then `project list` lists it; `project remove <its path>` then `project list` is empty. Use a small helper running `alas-host` with arguments and returning (status, stdout, stderr) through `AlasHostProcess`.
- [ ] **Step 2: Run** `touch Packages/AlasCore/Sources/alas-host/main.swift && swift test --package-path Packages/AlasCore --filter AlasHostExecutableTests` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — Expected: PASS. Manually: start the host on the scratch profile, `project add` through it, and `restart` (expect the "not a launch agent" message).
- [ ] **Step 5: Commit** `feat(host): configure settings and projects from the command line`

### Task 7: `alas-host setup`

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Core/Setup/HostSetupModel.swift`
- Create: `Packages/AlasCore/Sources/alas-host/Terminal.swift` (raw mode via `termios`, alternate screen, key decoding, drawing)
- Create: `Packages/AlasCore/Sources/alas-host/Setup.swift` (runs the model in the terminal)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostSettingTests.swift` (the model is driven by the settings table)

**Interfaces:**
- Consumes: `HostSettingCatalog.all(for:)`, `HostProfileWrite`, `DataDirectoryHolder`, the project commands' functions from Task 6, `HostSocketServer.request(.remotePairingCode)`.
- Produces: `public struct HostSetupModel: Equatable { public init(config: AppConfig, projects: [ProjectSnapshot]); public mutating func handle(_ key: HostSetupKey) -> HostSetupEffect?; public var screen: HostSetupScreen; public var changedConfig: AppConfig; public var isDirty: Bool }` with `HostSetupKey` (`up, down, enter, escape, character(Character), backspace, tab`) and `HostSetupEffect` (`save, quit, addProject, removeProject(String), showPairingCode`).
- Screens: a section list (Reachability, Agents, Projects, Unattended behavior, Worktrees, Pair a device, Save and quit); each section lists its settings with values; Enter toggles a bool, cycles a choice, or edits text in place (Enter confirms, Escape cancels). Saving asks `Restart the host now? This ends running sessions and runs. [now / later]`.

- [ ] **Step 1: Write the failing tests** (model only):
  - `togglingABoolMarksTheConfigDirty`: enter Unattended behavior, Enter on auto-resume → `changedConfig.harness.acpAutoResumeAfterUsageLimit` flipped, `isDirty`.
  - `editingTextIsCancelledByEscape`: edit `worktrees.baseBranch`, type `dev`, Escape → unchanged, not dirty; again with Enter → `"dev"`.
  - `choosingLANNeedsAnExplicitPick`: cycling reachability from loopback never lands on `.lan` without a keypress on that row (initial model of an upgraded profile shows `loopback`).
  - `saveEffectOnlyWhenDirty`: Save with no changes returns `.quit`, with changes `.save`.
- [ ] **Step 2: Run** `swift test --package-path Packages/AlasCore --filter HostSettingTests` — Expected: FAIL.
- [ ] **Step 3: Implement** the model, then the terminal layer and `setup` command. The terminal layer restores the terminal on exit and on SIGINT/SIGTERM; it refuses (`setup needs a terminal`) when stdin is not a TTY. Setup refuses up front when the app holds the profile.
- [ ] **Step 4: Run** the tests — Expected: PASS. Manually over a real terminal (and `ssh localhost` if available): change each section, save, choose later; rerun and see the new values; with a host running, Pair a device shows a code.
- [ ] **Step 5: Commit** `feat(host): add an interactive setup`

### Task 8: Documentation

**Files:**
- Modify: `docs/headless-host.md` (setup, `config`, `project`, `restart`, the reachability modes with the LAN note and plain HTTP, `host.port`, the app-holds-the-profile refusal; replace the hand-written `app.json` instructions with `alas-host setup`)
- Modify: `CHANGELOG.md` (one Unreleased entry in the file's existing style)
- Modify: `docs/superpowers/specs/2026-10-21-alas-host-setup-design.md` only if the build deviated

- [ ] **Step 1:** Update the docs; no build (documentation-only).
- [ ] **Step 2: Commit** `docs: describe alas-host setup and configuration`
