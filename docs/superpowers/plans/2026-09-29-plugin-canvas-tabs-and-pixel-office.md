# Plugin Canvas Tabs and Pixel Office Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship plugin API 2 (canvas center tabs with a frame clock, framebuffer presentation, accessible regions, `session/focus`) in Release behind an opt-in setting, and the Pixel Office plugin that uses it.

**Architecture:** The Swift side extends the existing `Alas/Sources/Plugins/` stack bottom-up. First `PluginManifest` (API 2, tabs), then `PluginRuntime` (the `alas.present` import), then `PluginHost` (frames, regions, tick, click, `session/focus`), then `PluginManager` (disable/revoke, project reconciliation, tick loop), then `AppState` ownership, the Settings pane, and the `Tab.plugin` center tab. The Rust side adds an `alas-plugin` SDK crate, moves `hello-workspace` onto it, and builds `pixel-office` as layout, simulation and renderer modules. Each module is pure and testable on the host target.

**Tech Stack:**
- Swift 5.9+, SwiftUI/AppKit, WasmKit (pinned), Swift Testing, xcodegen.
- Rust 1.98.1 (`wasm32-unknown-unknown`), `serde`/`serde_json`, `png` as a build dependency only.

**Spec:** `docs/superpowers/specs/2026-09-29-plugin-canvas-tabs-and-pixel-office-design.md`, built on `docs/superpowers/specs/2026-09-28-plugin-contract-v1-design.md`.

## Global Constraints

- Code, comments, logs and UI strings are in English.
- Commit titles use Conventional Commits (`type(scope): summary`). **No** `Co-Authored-By` trailers, no "Generated with" footers, no 🤖, and no AI attribution anywhere.
- Tests use Swift Testing (`import Testing`), not XCTest. Follow the AGENTS.md testing policy:
  - extend existing suites and parameterise variants;
  - never synchronise with a fixed `Task.sleep`;
  - no `.serialized` or new `@MainActor` suites without a stated reason (`PluginHostTests` is already `@MainActor` because `PluginHost` is).
- After adding any new Swift file under `Alas/` or `AlasTests/`, run `xcodegen` and commit `Alas.xcodeproj` with it. A new test file does not run until the project is regenerated.
- Run focused tests only:
  ```bash
  ALAS_FFF_TARGET_ARCH=arm64 ALAS_ZMX_TARGET_ARCH=arm64 xcodebuild -project Alas.xcodeproj -scheme Alas \
    -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation \
    -only-testing AlasTests/<SuiteName> test > /tmp/alas-test.log 2>&1
  grep -E "✔|✘|TEST SUCCEEDED|TEST FAILED|error:" /tmp/alas-test.log | tail -30
  ```
  - Swift Testing results are the `✔`/`✘` lines. "Executed 0 tests" from the XCTest bridge is meaningless.
  - Never pipe `xcodebuild` straight into `tail` (it hides the exit status).
  - If the zmx build phase fails with a network timeout: `git submodule deinit -f ThirdParty/zmx`, add `ALAS_ZMX_OPTIONAL=1`, run the tests, then `git submodule update --init ThirdParty/zmx`.
  - Never `pkill` the Alas app binary. Only kill `xcodebuild`.
- Build-only check when no suite covers a change: the same command with `-quiet build` instead of `-only-testing … test`.
- Rust crates in `plugins/` are standalone (`[workspace]` table in each `Cargo.toml`), use toolchain `1.98.1`, and must pass `cargo test --locked` on the host target. Commit `Cargo.lock`.
- Limits (verbatim from the spec):
  - frame width and height 1–1024;
  - frame `len` ≤ 4 MiB, a multiple of `width × 4`;
  - ≤ 4 tabs per manifest, tab title ≤ 40 characters;
  - ≤ 256 regions per tab;
  - region `id` ≤ 64 bytes, `label` ≤ 200 scalars;
  - tick at 15 fps in Release and 5 fps in Debug.
- Wire names:
  - methods and notifications: `tick {dt}`, `canvas/regions {tab, regions:[{id,label,rect:[x,y,w,h]}]}`, `canvas/click {tab, region}`, `session/focus {id}`;
  - capability `session.focus`;
  - import `alas.present(tab, ptr, len, width)`;
  - error codes `-32001` (not granted), `-32003` (action failed), `-32602` (invalid params).
- The plugins setting is `AppConfig.pluginsEnabled` and defaults to `false`.

## Review Focus

These are the failure modes most likely to bite a user that the spec implies but doesn't spell out. Each one has a test in its owning task.

1. **A frame presented during a call that then traps must never reach the screen**, and the next call must not resurface it. Owner: Task 2, test `aFramePresentedBeforeATrapIsDiscarded`.
2. **The first tick after a tab is hidden and shown again carries `dt: 0`**, not the minutes the tab was hidden. Otherwise the office teleports every character. Owner: Task 3, `ticksNeedAVisibleTabAndResumeWithZeroDelta`.
3. **An oversized region label or id is truncated and the plugin keeps running**, rather than failing. Owner: Task 3, `oversizedRegionTextIsTruncatedNotFatal`.
4. **A session that ends between the snapshot and the click** gets a `-32003` reply. The office logs a warning and keeps running. Owner: Task 3 (host reply) and Task 14 (`anErrorReplyIsLoggedAndIgnored`).
5. **A project with more worktrees than fit** gets a "+N more" sign, and the frame stays at or below 1024 pixels high instead of failing the plugin with an oversized frame. Owner: Task 12, `overflowingWorktreesAreSummarisedAndHeightIsCapped`.

---

## File Map

**Swift: modify**
- `Alas/Sources/Plugins/PluginManifest.swift`: API 2, the `session.focus` capability, `tabs`.
- `Alas/Sources/Plugins/PluginRuntime.swift`: the `alas.present` import, `PluginDelivery`, frame limits.
- `Alas/Sources/Plugins/PluginMessages.swift`: new payloads (tick, click, regions, session focus).
- `Alas/Sources/Plugins/PluginHost.swift`: frames, regions, visibility and tick, click, `session/focus`, `focusSession` action.
- `Alas/Sources/Plugins/PluginTrust.swift`: the disabled-plugin set.
- `Alas/Sources/Plugins/PluginManager.swift`: enable/disable, revoke, reconcile, tick loop, shutdown, lookups.
- `Alas/Sources/Plugins/AppState+Plugins.swift`: manager lifecycle, `focusSession`, tab contributions.
- `Alas/Sources/Plugins/PluginsWindow.swift`: read `state.pluginManager`.
- `Alas/Sources/Persistence/AppConfig.swift`: `pluginsEnabled`.
- `Alas/Sources/App/AppState.swift`: stored `pluginManager`.
- `Alas/Sources/App/RootView.swift`: start plugins at launch.
- `Alas/Sources/App/AlasApp.swift`: View → Plugins submenu.
- `Alas/Sources/Settings/AdvancedPane.swift`: the Plugins toggle.
- `Alas/Sources/Settings/SettingsNavView.swift`: `.plugins` section.
- `Alas/Sources/Settings/SettingsWindow.swift`: route `.plugins`.
- `Alas/Sources/Center/Tab.swift`: `case plugin(PluginTabState)`.
- `Alas/Sources/Center/TabsManager.swift`: `openOrFocusPluginTab`.
- `Alas/Sources/Center/CenterPaneView.swift`: render `.plugin`.
- `.github/workflows/build.yml`: the Rust test matrix.

**Swift: create**
- `Alas/Sources/Plugins/PluginsPane.swift`: the Settings → Plugins pane and approval sheet.
- `Alas/Sources/Plugins/PluginTabView.swift`: canvas, regions, placeholder, `PluginTabContent`, `PluginCanvasLayout`.
- `AlasTests/PluginTabTests.swift`: scale fit and placeholder decision.

**Swift tests: modify** `PluginWATFixture.swift`, `PluginManifestTests.swift`, `PluginRuntimeTests.swift`, `PluginHostTests.swift`, `PluginManagerDiscoveryTests.swift`.

**Rust: create**
- `plugins/alas-plugin/{Cargo.toml,Cargo.lock,src/lib.rs}`
- `plugins/pixel-office/{Cargo.toml,Cargo.lock,build.rs,build.sh,plugin.json,.gitignore}`
- `plugins/pixel-office/assets/{palette.hex,characters.png,furniture.png,overlays.png,font.png}`
- `plugins/pixel-office/src/{lib.rs,sprites.rs,canvas.rs,look.rs,layout.rs,sim.rs,render.rs}`

**Rust: modify** `plugins/samples/hello-workspace/{Cargo.toml,Cargo.lock,src/lib.rs}`.

**Docs:** create `docs/plugins/api-v2.md`; modify `docs/plugins/{README.md,getting-started.md,writing-plugins.md}`.

---

### Task 1: Manifest API 2, tab contributions, `session.focus`

**Files:**
- Modify: `Alas/Sources/Plugins/PluginManifest.swift`
- Test: `AlasTests/PluginManifestTests.swift`

**Interfaces:**
- Produces:
  - `PluginCapability.sessionFocus` (`"session.focus"`);
  - `struct PluginTabContribution: Equatable, Sendable { let id: String; let title: String }`;
  - `PluginManifest.tabs: [PluginTabContribution]` (a `var` with default `[]`, so the memberwise init keeps working);
  - `PluginManifest.supportedAPIVersions == [1, 2]`;
  - `PluginManifestError.invalidTab(String)`.

- [ ] **Step 1: Update and add the failing tests**

In `AlasTests/PluginManifestTests.swift`:
- change the `api":2` rejection case to `api":3` with `.unsupportedAPI(3)`;
- replace `unsupportedAPIMessageNamesBothVersions`;
- add the tab cases and tests below.

```swift
        (#"{"id":"io.x.h","name":"H","version":"1","api":3,"entry":"p.wasm"}"#, .unsupportedAPI(3)),
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","contributes":{"tabs":[{"id":"a","title":"A"},{"id":"a","title":"B"}]}}"#, .invalidTab("duplicate tab id \"a\"")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","contributes":{"tabs":[{"id":"a","title":" "}]}}"#, .invalidTab("tab \"a\" needs a title of 1 to 40 characters")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","contributes":{"tabs":[{"id":"A!","title":"T"}]}}"#, .invalidTab("invalid tab id \"A!\"")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","contributes":{"tabs":[{"id":"a","title":"T"},{"id":"b","title":"T"},{"id":"c","title":"T"},{"id":"d","title":"T"},{"id":"e","title":"T"}]}}"#, .invalidTab("at most 4 tabs")),
```

```swift
    @Test func unsupportedAPIMessageNamesBothVersions() {
        #expect(PluginManifestError.unsupportedAPI(3).description == "requires plugin API 3; this Alas supports 1, 2")
    }

    @Test func apiTwoManifestsDeclareTabsAndApiOneManifestsIgnoreThem() throws {
        let tabs = #""contributes":{"tabs":[{"id":"office","title":"Office"}]}"#
        let v2 = try PluginManifest.parse(Data(#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","capabilities":["session.focus"],\#(tabs)}"#.utf8))
        #expect(v2.tabs == [PluginTabContribution(id: "office", title: "Office")])
        #expect(v2.capabilities == [.sessionFocus])
        let v1 = try PluginManifest.parse(Data(#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"p.wasm",\#(tabs)}"#.utf8))
        #expect(v1.tabs.isEmpty)
    }
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run the focused command with `-only-testing AlasTests/PluginManifestTests`.
Expected: compile errors (`invalidTab`, `tabs` and `sessionFocus` don't exist yet).

- [ ] **Step 3: Implement**

In `PluginManifest.swift`:

```swift
enum PluginCapability: String, Codable, CaseIterable, Sendable, Hashable {
    case workspaceRead = "workspace.read"
    case worktreeSwitch = "worktree.switch"
    case sessionFocus = "session.focus"

    var summary: String {
        switch self {
        case .workspaceRead: "Read this project's worktrees and what their agent sessions are doing"
        case .worktreeSwitch: "Switch the selected worktree"
        case .sessionFocus: "Open agent sessions in this project"
        }
    }
}

/// A canvas tab the plugin draws with `alas.present`. API 2 and later.
struct PluginTabContribution: Equatable, Sendable {
    let id: String
    let title: String
}
```

Add the error case and its description:

```swift
    case invalidTab(String)
    // description:
        case .invalidTab(let reason):
            "invalid tab contribution: \(reason)"
```

In `PluginManifest`:
- `static let supportedAPIVersions = [1, 2]`;
- add the stored property `var tabs: [PluginTabContribution] = []` after `capabilities`;
- `static let maxTabs = 4`, `static let maxTabTitleLength = 40`.

Extend `Raw` to decode `contributes`:

```swift
        struct RawTab: Decodable {
            let id: String?
            let title: String?
        }
        struct RawContributes: Decodable {
            let tabs: [RawTab]?
        }
```

Add `let contributes: RawContributes?` to `Raw`, `contributes` to its `CodingKeys`, and `contributes = try container.decodeIfPresent(RawContributes.self, forKey: .contributes)` in its init.

After the entry check, replace the `return`:

```swift
        // `contributes` is inert before API 2, so older manifests are not validated against it.
        let tabs = api >= 2 ? try parseTabs(raw.contributes?.tabs ?? []) : []
        return PluginManifest(
            id: id, name: name, version: version, api: api, entry: entry,
            capabilities: capabilities, tabs: tabs)
    }

    private static func parseTabs(_ raw: [Raw.RawTab]) throws(PluginManifestError) -> [PluginTabContribution] {
        guard raw.count <= maxTabs else { throw .invalidTab("at most \(maxTabs) tabs") }
        var tabs: [PluginTabContribution] = []
        for entry in raw {
            let id = entry.id ?? ""
            guard id.wholeMatch(of: /[a-z0-9-]+(\.[a-z0-9-]+)*/) != nil else { throw .invalidTab("invalid tab id \"\(id)\"") }
            guard !tabs.contains(where: { $0.id == id }) else { throw .invalidTab("duplicate tab id \"\(id)\"") }
            let title = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...maxTabTitleLength).contains(title.count) else {
                throw .invalidTab("tab \"\(id)\" needs a title of 1 to \(maxTabTitleLength) characters")
            }
            tabs.append(PluginTabContribution(id: id, title: title))
        }
        return tabs
    }
```

`RawTab` and `RawContributes` must be nested in `Raw`, or at the same level; `parseTabs` references them as `Raw.RawTab`. Keep `parse` generic over its nested types as it is now. If nesting inside the function blocks the reference from `parseTabs`, move `Raw` and its nested types to `private struct` at file scope.

- [ ] **Step 4: Run the tests and confirm they pass**

Same command. Expected: all `PluginManifestTests` pass (`✔`).

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Plugins/PluginManifest.swift AlasTests/PluginManifestTests.swift
git commit -m "feat(plugins): accept API 2 manifests with canvas tab contributions"
```

---

### Task 2: `alas.present` in the runtime

**Files:**
- Modify: `Alas/Sources/Plugins/PluginRuntime.swift`, `Alas/Sources/Plugins/PluginHost.swift` (call site only), `AlasTests/PluginWATFixture.swift`
- Test: `AlasTests/PluginRuntimeTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `struct PluginFrame: Equatable, Sendable { let width: Int; let height: Int; let pixels: Data }`;
  - `struct PluginDelivery: Sendable { var messages: [Data]; var frames: [Int: PluginFrame] }`;
  - `PluginRuntime.load(wasm:limits:tabCount:)`, where `tabCount: Int?` defaults to `nil` (nil means `alas.present` is not defined, as for API 1);
  - `PluginRuntime.handle(_:) async throws -> PluginDelivery`;
  - `PluginLimits.maxFrameDimension = 1024`, `PluginLimits.maxFrameBytes = 4 << 20`;
  - `PluginRuntimeError.badFrame(String)`, described as `"plugin presented an invalid frame: \(reason)"`;
  - fixture step `PluginFixtureStep.present(tab: Int, ptr: Int, len: Int, width: Int)`.

- [ ] **Step 1: Extend the fixture**

In `PluginWATFixture.swift`:
- add the case `case present(tab: Int, ptr: Int, len: Int, width: Int)` to `PluginFixtureStep`;
- in `wasm(_:allocReturns:)`, handle it in the step switch:

```swift
                case let .present(tab, ptr, len, width):
                    body += "(call $present (i32.const \(tab)) (i32.const \(ptr)) (i32.const \(len)) (i32.const \(width)))"
```

- declare the import only when a script uses it, so API 1 fixtures stay loadable without it:

```swift
        let usesPresent = script.joined().contains { if case .present = $0 { true } else { false } }
        let presentImport = usesPresent
            ? #"(import "alas" "present" (func $present (param i32 i32 i32 i32)))"# : ""
```

- insert `\(presentImport)` on the line after the `send` import in the module text.

- [ ] **Step 2: Write the failing tests**

In `PluginRuntimeTests.swift`:
- update `returnsMessagesSentDuringTheCall` to read `.messages`:

```swift
        let sent = try await runtime.handle(Data("hi".utf8)).messages
```

- add:

```swift
    @Test func aPresentedFrameIsCopiedOut() async throws {
        let runtime = try await PluginRuntime.load(
            wasm: PluginWATFixture.wasm([[.present(tab: 0, ptr: 0, len: 24, width: 2)]]),
            limits: Self.limits, tabCount: 1)
        let delivery = try await runtime.handle(Data())
        #expect(delivery.frames == [0: PluginFrame(width: 2, height: 3, pixels: Data(count: 24))])
    }

    @Test(arguments: [
        (PluginFixtureStep.present(tab: 1, ptr: 0, len: 4, width: 1), "not declared"),
        (.present(tab: 0, ptr: 0, len: 4, width: 0), "width 0"),
        (.present(tab: 0, ptr: 0, len: 4100, width: 1025), "width 1025"),
        (.present(tab: 0, ptr: 0, len: 20, width: 2), "does not fit"),
        (.present(tab: 0, ptr: 0, len: 4100, width: 1), "does not fit"),
        (.present(tab: 0, ptr: 0, len: 5 << 20, width: 1024), "frame size limit"),
        (.present(tab: 0, ptr: 65_000, len: 4096, width: 1024), "invalid memory range"),
    ])
    func invalidFramesSurfaceAsErrors(step: PluginFixtureStep, fragment: String) async throws {
        let runtime = try await PluginRuntime.load(
            wasm: PluginWATFixture.wasm([[step]]), limits: Self.limits, tabCount: 1)
        let error = await #expect(throws: PluginRuntimeError.self) { try await runtime.handle(Data()) }
        #expect(error?.description.contains(fragment) == true)
    }

    /// Review focus 1: a trapping call's frame must not survive into the next call's delivery.
    @Test func aFramePresentedBeforeATrapIsDiscarded() async throws {
        let runtime = try await PluginRuntime.load(
            wasm: PluginWATFixture.wasm([[.present(tab: 0, ptr: 0, len: 4, width: 1), .trap], []]),
            limits: Self.limits, tabCount: 1)
        await #expect(throws: PluginRuntimeError.self) { _ = try await runtime.handle(Data()) }
        #expect(try await runtime.handle(Data()).frames.isEmpty)
    }
```

- add an API 1 module that imports `present` to the `unloadableModulesFailToLoad` arguments:

```swift
        module(extra: #"(import "alas" "present" (func (param i32 i32 i32 i32)))"#),
```

- [ ] **Step 3: Run the tests and confirm they fail**

`-only-testing AlasTests/PluginRuntimeTests`. Expected: compile errors (`PluginFrame`, `tabCount` and `.frames` are missing).

- [ ] **Step 4: Implement**

In `PluginRuntime.swift`:
- add `var maxFrameDimension = 1024` and `var maxFrameBytes = 4 << 20` to `PluginLimits`;
- add `case badFrame(String)` to `PluginRuntimeError` with `case .badFrame(let reason): "plugin presented an invalid frame: \(reason)"`;
- add the new types:

```swift
/// RGBA8, non-premultiplied, row-major, top-left origin.
struct PluginFrame: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixels: Data
}

/// What one `alas_handle` call produced.
struct PluginDelivery: Sendable {
    var messages: [Data] = []
    /// Last frame per tab index presented during the call.
    var frames: [Int: PluginFrame] = [:]
}
```

In `PluginRuntime`:
- add `private let tabCount: Int?` and `private var frames: [Int: PluginFrame] = [:]`;
- change `private init(limits:)` to `private init(limits: PluginLimits, tabCount: Int?)` and store it;
- change `load`:

```swift
    /// `tabCount` is nil for API 1 plugins: `alas.present` is then left undefined,
    /// so a module that imports it fails to load.
    static func load(wasm: [UInt8], limits: PluginLimits, tabCount: Int? = nil) async throws -> PluginRuntime {
        let runtime = PluginRuntime(limits: limits, tabCount: tabCount)
        try await runtime.run { try runtime.instantiate(wasm) }
        return runtime
    }

    func handle(_ message: Data) async throws -> PluginDelivery {
        try await run { try self.deliver(message) }
    }
```

- in `instantiate`, after the `send` definition:

```swift
        if tabCount != nil {
            imports.define(module: "alas", name: "present", Function(store: store, parameters: [.i32, .i32, .i32, .i32]) { [unowned self] caller, args in
                try self.present(caller, tab: args[0].i32, ptr: args[1].i32, len: args[2].i32, width: args[3].i32)
                return []
            })
        }
```

- in `deliver`: reset `frames = [:]` next to `outbox = []`, change the return type to `PluginDelivery`, and return `PluginDelivery(messages: outbox, frames: frames)`. A throw leaves the frames unreturned, and the next call resets them. That is Review Focus 1;
- add:

```swift
    private func present(_ caller: borrowing Caller, tab: UInt32, ptr: UInt32, len: UInt32, width: UInt32) throws {
        guard let tabCount, Int(tab) < tabCount else { throw record(.badFrame("tab \(tab) is not declared")) }
        guard (1...limits.maxFrameDimension).contains(Int(width)) else {
            throw record(.badFrame("width \(width) is out of range"))
        }
        guard Int(len) <= limits.maxFrameBytes else {
            throw record(.badFrame("\(len) bytes exceeds the frame size limit"))
        }
        let rowBytes = Int(width) * 4
        guard Int(len) % rowBytes == 0, (1...limits.maxFrameDimension).contains(Int(len) / rowBytes) else {
            throw record(.badFrame("length \(len) does not fit width \(width)"))
        }
        guard let memory = caller.instance?.exports[memory: "memory"],
              Int(ptr) + Int(len) <= memory.byteCount
        else { throw record(.badGuestRange(ptr: ptr, len: len)) }
        frames[Int(tab)] = PluginFrame(
            width: Int(width), height: Int(len) / rowBytes,
            pixels: memory.withUnsafeBufferPointer(offset: UInt(ptr), count: Int(len)) { Data($0) })
    }
```

In `PluginHost.swift`, make the minimal call-site change so it compiles. In `deliver`, `let sent: [Data]` becomes `let sent: [Data]` assigned from `try await runtime.handle(message).messages`. Frames are wired in Task 3.

- [ ] **Step 5: Run the tests and confirm they pass**

`-only-testing AlasTests/PluginRuntimeTests` and `-only-testing AlasTests/PluginHostTests` (the host suite must still pass). Expected: all `✔`.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Plugins/PluginRuntime.swift Alas/Sources/Plugins/PluginHost.swift AlasTests/PluginWATFixture.swift AlasTests/PluginRuntimeTests.swift
git commit -m "feat(plugins): let API 2 plugins present RGBA frames"
```

---

### Task 3: Host frames, regions, tick, click, `session/focus`

**Files:**
- Modify: `Alas/Sources/Plugins/PluginHost.swift`, `Alas/Sources/Plugins/PluginMessages.swift`, `Alas/Sources/Plugins/PluginsWindow.swift` (actions fallback), `AlasTests/PluginManagerDiscoveryTests.swift` (actions literal)
- Test: `AlasTests/PluginHostTests.swift`

**Interfaces:**
- Consumes: `PluginDelivery`, `PluginFrame`, and `PluginRuntime.load(wasm:limits:tabCount:)` from Task 2; `PluginManifest.tabs` and `.sessionFocus` from Task 1.
- Produces:
  - `PluginHostActions.focusSession: (String) -> Bool`, plus `@MainActor static var inert: PluginHostActions`;
  - `struct PluginRegion: Codable, Equatable, Sendable { let id: String; let label: String; let rect: [Int] }`;
  - on `PluginHost`:
    - `private(set) var frames: [Int: PluginFrame]` and `private(set) var regions: [Int: [PluginRegion]]`;
    - `func setViewVisible(_ visible: Bool)` and `var isTicking: Bool`;
    - `func tick(at now: ContinuousClock.Instant) async`;
    - `func click(tab: Int, region: String) async`;
    - `static let maxRegions = 256`, `static let regionIDByteLimit = 64`, `static let regionLabelLimit = 200`.

- [ ] **Step 1: Write the failing tests**

In `PluginHostTests.swift`:
- add `var focused: [String] = []` to `Recorder`;
- change `makeHost` to take a manifest and use `focusSession`:

```swift
    static let v1Manifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":1,"entry":"p.wasm"}"#
    static let v2Manifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":2,"entry":"p.wasm","contributes":{"tabs":[{"id":"t","title":"T"}]}}"#

    func makeHost(
        _ script: [[PluginFixtureStep]],
        grants: Set<PluginCapability> = [],
        recorder: Recorder = Recorder(),
        limits: PluginLimits = PluginHostTests.limits,
        manifest: String = PluginHostTests.v1Manifest
    ) throws -> PluginHost {
        PluginHost(
            manifest: try PluginManifest.parse(Data(manifest.utf8)),
            wasm: try PluginWATFixture.wasm(script),
            project: PluginProjectRef(id: "proj", name: "Project"),
            grants: grants,
            actions: PluginHostActions(
                snapshot: { PluginWorkspaceSnapshot(worktrees: []) },
                switchWorktree: { id in
                    recorder.switched.append(id)
                    return id == "wt"
                },
                focusSession: { id in
                    recorder.focused.append(id)
                    return id == "s1"
                }),
            limits: limits)
    }

    func ticks(_ host: PluginHost) -> [String] {
        host.trace.filter { $0.direction == .toPlugin && $0.text.contains(#""method":"tick""#) }.map(\.text)
    }
```

- add the tests:

```swift
    private static let regionsR = #"{"jsonrpc":"2.0","method":"canvas/regions","params":{"tab":0,"regions":[{"id":"r","label":"R","rect":[0,0,4,4]}]}}"#

    /// Review focus 2: hiding the tab resets the clock, so the next tick does not carry the hidden time.
    @Test func ticksNeedAVisibleTabAndResumeWithZeroDelta() async throws {
        let host = try makeHost([[.send(activateOK)]], manifest: Self.v2Manifest)
        await host.activate()
        let start = ContinuousClock.now
        await host.tick(at: start)
        #expect(ticks(host).isEmpty)
        host.setViewVisible(true)
        await host.tick(at: start)
        await host.tick(at: start + .milliseconds(66))
        host.setViewVisible(false)
        await host.tick(at: start + .seconds(1))
        host.setViewVisible(true)
        await host.tick(at: start + .seconds(600))
        #expect(ticks(host).map { $0.contains(#""dt":0"#) } == [true, false, true])
        #expect(ticks(host)[1].contains(#""dt":66"#))
    }

    @Test func aTickIsDroppedWhileADeliveryIsInFlight() async throws {
        let host = try makeHost([[.send(activateOK)]], manifest: Self.v2Manifest)
        await host.activate()
        host.setViewVisible(true)
        let first = Task { await host.tick(at: .now) }
        // The tick is traced just before the host suspends inside the plugin call.
        var spins = 0
        while ticks(host).isEmpty, spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        try #require(!ticks(host).isEmpty)
        await host.tick(at: .now)
        await first.value
        #expect(ticks(host).count == 1)
    }

    @Test func presentedFramesAndRegionsAreKeptUntilTheHostFails() async throws {
        let host = try makeHost(
            [[.send(activateOK), .send(Self.regionsR), .present(tab: 0, ptr: 0, len: 16, width: 2)], [.trap]],
            manifest: Self.v2Manifest)
        await host.activate()
        #expect(host.frames[0]?.height == 2)
        #expect(host.regions[0]?.map(\.id) == ["r"])
        host.setViewVisible(true)
        await host.tick(at: .now)
        #expect(host.frames.isEmpty)
        #expect(host.regions.isEmpty)
    }

    @Test func aClickOnAKnownRegionReachesThePlugin() async throws {
        let host = try makeHost([[.send(activateOK), .send(Self.regionsR)]], manifest: Self.v2Manifest)
        await host.activate()
        await host.click(tab: 0, region: "nope")
        await host.click(tab: 0, region: "r")
        let clicks = host.trace.filter { $0.direction == .toPlugin && $0.text.contains("canvas/click") }
        #expect(clicks.count == 1)
        #expect(clicks.first?.text.contains(#""region":"r""#) == true)
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","method":"canvas/regions","params":{"tab":3,"regions":[]}}"#,
        #"{"jsonrpc":"2.0","method":"canvas/regions","params":{"tab":0,"regions":[{"id":"r","label":"R","rect":[0,0,4]}]}}"#,
        #"{"jsonrpc":"2.0","method":"canvas/regions","params":{"tab":0}}"#,
    ])
    func malformedRegionsStopThePlugin(message: String) async throws {
        let host = try makeHost([[.send(activateOK), .send(message)]], manifest: Self.v2Manifest)
        await host.activate()
        guard case .failed(let reason) = host.state else {
            Issue.record("expected failed, got \(host.state)")
            return
        }
        #expect(reason.contains("canvas/regions"))
    }

    /// Review focus 3.
    @Test func oversizedRegionTextIsTruncatedNotFatal() async throws {
        let id = String(repeating: "i", count: 100)
        let label = String(repeating: "l", count: 300)
        var limits = Self.limits
        limits.maxMessageBytes = 1 << 14
        let host = try makeHost([[
            .send(activateOK),
            .send(#"{"jsonrpc":"2.0","method":"canvas/regions","params":{"tab":0,"regions":[{"id":"\#(id)","label":"\#(label)","rect":[0,0,1,1]}]}}"#),
        ]], limits: limits, manifest: Self.v2Manifest)
        await host.activate()
        #expect(host.state == .active)
        #expect(host.regions[0]?.first?.id.utf8.count == PluginHost.regionIDByteLimit)
        #expect(host.regions[0]?.first?.label.unicodeScalars.count == PluginHost.regionLabelLimit)
    }

    /// Review focus 4 (host side): a session that ended answers -32003 and the plugin keeps running.
    @Test(arguments: [
        (Set<PluginCapability>(), "s1", #""code":-32001"#, [String]()),
        ([.sessionFocus], "s1", #""result":{}"#, ["s1"]),
        ([.sessionFocus], "gone", #""code":-32003"#, ["gone"]),
    ])
    func sessionFocusIsCheckedAgainstGrants(
        grants: Set<PluginCapability>, id: String, reply: String, focused: [String]
    ) async throws {
        let recorder = Recorder()
        let request = #"{"jsonrpc":"2.0","id":1,"method":"session/focus","params":{"id":"\#(id)"}}"#
        let host = try makeHost([[.send(activateOK), .send(request)]], grants: grants, recorder: recorder)
        await host.activate()
        #expect(host.state == .active)
        #expect(recorder.focused == focused)
        #expect(lastReply(host)?.contains(reply) == true)
    }
```

If `@Test(arguments:)` rejects the 4-tuple, use a `struct FocusCase: Sendable` wrapper, the same pattern as `RequestCase`.

- [ ] **Step 2: Run the tests and confirm they fail**

`-only-testing AlasTests/PluginHostTests`. Expected: compile errors (`focusSession`, `setViewVisible`, `tick`, `click`, `frames` and `regions` don't exist yet).

- [ ] **Step 3: Add the message payloads**

In `PluginMessages.swift`:

```swift
struct PluginTickParams: Codable, Equatable, Sendable {
    let dt: Int
}

struct PluginClickParams: Codable, Equatable, Sendable {
    let tab: Int
    let region: String
}

struct PluginRegion: Codable, Equatable, Sendable {
    let id: String
    let label: String
    /// `[x, y, w, h]` in frame pixels.
    let rect: [Int]
}

struct PluginRegionsParams: Codable, Equatable, Sendable {
    let tab: Int
    let regions: [PluginRegion]
}

struct PluginSessionFocusParams: Codable, Equatable, Sendable {
    let id: String
}
```

- [ ] **Step 4: Implement the host**

In `PluginHost.swift`:
- actions:

```swift
@MainActor
struct PluginHostActions {
    var snapshot: () -> PluginWorkspaceSnapshot
    /// Returns false when `id` is not a worktree of this project.
    var switchWorktree: (String) -> Bool
    /// Returns false when `id` is not an active session of this project.
    var focusSession: (String) -> Bool

    /// For hosts whose owner is gone: reads nothing and refuses every action.
    static var inert: PluginHostActions {
        PluginHostActions(
            snapshot: { PluginWorkspaceSnapshot(worktrees: []) },
            switchWorktree: { _ in false },
            focusSession: { _ in false })
    }
}
```

- add `"session/focus": .sessionFocus` to `requiredCapability`;
- add the constants `static let maxRegions = 256`, `static let regionIDByteLimit = 64`, `static let regionLabelLimit = 200`;
- add the state:

```swift
    private(set) var frames: [Int: PluginFrame] = [:]
    private(set) var regions: [Int: [PluginRegion]] = [:]
    @ObservationIgnored private var visibleViews = 0
    @ObservationIgnored private var lastTick: ContinuousClock.Instant?
    @ObservationIgnored private var deliveriesInFlight = 0
```

- in `activate()`, pass the tab count: `PluginRuntime.load(wasm: wasm, limits: limits, tabCount: manifest.api >= 2 ? manifest.tabs.count : nil)`;
- add a `clearCanvas()` helper and call it from `fail(_:)`, from the end of `deactivate()` (where `state = .stopped`), and at the start of `activate()` next to `trace = []`:

```swift
    private func clearCanvas() {
        frames = [:]
        regions = [:]
        lastTick = nil
    }
```

- visibility, tick and click:

```swift
    /// Each visible instance of one of this plugin's tabs holds one count.
    func setViewVisible(_ visible: Bool) {
        visibleViews = max(0, visibleViews + (visible ? 1 : -1))
        if visibleViews == 0 { lastTick = nil }
    }

    var isTicking: Bool { state == .active && visibleViews > 0 && !manifest.tabs.isEmpty }

    /// Dropped, not queued, while any delivery is still running, so a slow plugin loses frames instead of lagging.
    func tick(at now: ContinuousClock.Instant) async {
        guard isTicking, deliveriesInFlight == 0 else { return }
        let dt = lastTick.map { max(0, Int(((now - $0) / .milliseconds(1)).rounded())) } ?? 0
        lastTick = now
        await deliver(encode(JSONRPCEnvelope(id: nil, method: "tick", params: PluginTickParams(dt: dt))))
    }

    /// Only regions the plugin declared can be clicked.
    func click(tab: Int, region: String) async {
        guard state == .active, regions[tab]?.contains(where: { $0.id == region }) == true else { return }
        await deliver(encode(JSONRPCEnvelope(
            id: nil, method: "canvas/click", params: PluginClickParams(tab: tab, region: region))))
    }
```

- in `deliver(_:isActivation:)`:
  - add `deliveriesInFlight += 1` and `defer { deliveriesInFlight -= 1 }` at the top;
  - replace the handle call and apply frames:

```swift
            let delivery: PluginDelivery
            do {
                delivery = try await runtime.handle(message)
            } catch {
                fail(String(describing: error))
                return
            }
            guard isRunning, self.runtime === runtime else { return }
            frames.merge(delivery.frames) { _, new in new }
            for data in delivery.messages {
```

  Keep the loop body the same, with the `guard isRunning, self.runtime === runtime` it already has.
- notifications now return an outcome. In `process`, `case let (method?, nil): return handleNotification(method, data: data)`, then:

```swift
    /// Notifications never get replies. Bad logs are dropped; bad regions are a protocol violation,
    /// because a plugin that cannot describe its own canvas is broken rather than noisy.
    private func handleNotification(_ method: String, data: Data) -> Outcome {
        switch method {
        case "log":
            if let params = try? JSONDecoder().decode(PluginParams<PluginLogParams>.self, from: data).params,
               Self.logLevels.contains(params.level) {
                appendLog(params.level, params.message)
            }
            return .none
        case "canvas/regions":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginRegionsParams>.self, from: data).params,
                  manifest.tabs.indices.contains(params.tab),
                  params.regions.allSatisfy({ $0.rect.count == 4 })
            else { return .violation("plugin sent a malformed canvas/regions") }
            regions[params.tab] = params.regions.prefix(Self.maxRegions).map {
                PluginRegion(
                    id: Self.prefix($0.id, utf8Bytes: Self.regionIDByteLimit),
                    label: String(String.UnicodeScalarView($0.label.unicodeScalars.prefix(Self.regionLabelLimit))),
                    rect: $0.rect)
            }
            return .none
        default:
            return .none
        }
    }

    private static func prefix(_ text: String, utf8Bytes limit: Int) -> String {
        var used = 0
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix { scalar in
            used += UTF8.width(scalar)
            return used <= limit
        }))
    }
```

- in `handleRequest`, add a case before `default`:

```swift
        case "session/focus":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginSessionFocusParams>.self, from: data).params else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            guard actions.focusSession(params.id) else {
                return errorReply(id, code: -32003, "unknown session \(params.id)")
            }
            return encode(PluginResponse(id: id, result: PluginEmptyPayload(), error: nil))
```

- [ ] **Step 5: Fix the other `PluginHostActions` literals**

- In `PluginsWindow.swift`, replace the fallback `PluginHostActions(snapshot: …, switchWorktree: …)` with `.inert`.
- In `PluginManagerDiscoveryTests.swift`, replace `actions: { _ in PluginHostActions(snapshot: …, switchWorktree: …) }` with `actions: { _ in .inert }`.
- In `AppState+Plugins.swift`, add a temporary `focusSession: { _ in false }` argument. Task 5 replaces it.

- [ ] **Step 6: Run the tests and confirm they pass**

`-only-testing AlasTests/PluginHostTests`, then `AlasTests/PluginManagerDiscoveryTests`. Expected: all `✔`.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Plugins AlasTests/PluginHostTests.swift AlasTests/PluginManagerDiscoveryTests.swift
git commit -m "feat(plugins): deliver ticks and clicks and keep frames and regions per tab"
```

---

### Task 4: Manager: disable, revoke, reconcile, tick loop

**Files:**
- Modify: `Alas/Sources/Plugins/PluginTrust.swift`, `Alas/Sources/Plugins/PluginManager.swift`
- Test: `AlasTests/PluginManagerDiscoveryTests.swift`

**Interfaces:**
- Consumes: `PluginHost.isTicking`, `tick(at:)` and `deactivate()` from Task 3.
- Produces:
  - `PluginApprovalStore.isDisabled(id:) -> Bool` and `setDisabled(id:_:)`;
  - on `PluginManager`:
    - `isEnabled(_:) -> Bool`, `setEnabled(_:_:) async`, `revoke(_:) async`;
    - `reconcile() async`, `shutdown() async`;
    - `plugin(id:) -> Plugin?`, `host(pluginID:projectID:) -> PluginHost?`;
    - `static var tickInterval: Duration`.

- [ ] **Step 1: Write the failing tests**

Add to `PluginManagerDiscoveryTests.swift`. The helper installs one approved plugin and returns the pieces:

```swift
    @MainActor
    final class ProjectList {
        var projects: [ProjectConfig]
        init(_ projects: [ProjectConfig]) { self.projects = projects }
    }

    static func project(_ id: String) -> ProjectConfig {
        ProjectConfig(id: id, name: id, path: "/tmp/\(id)", color: "blue", addedAt: Date())
    }

    @MainActor
    func approvedManager(projects: ProjectList) async throws -> (PluginManager, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appending(path: "PluginReconcile-\(UUID().uuidString)")
        let suite = "PluginManagerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = root.appending(path: "p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"id":"io.x.p","name":"P","version":"1","api":1,"entry":"plugin.wasm"}"#.utf8)
            .write(to: dir.appending(path: "plugin.json"))
        try Data(try PluginWATFixture.wasm([[.send(#"{"jsonrpc":"2.0","id":0,"result":{}}"#)]]))
            .write(to: dir.appending(path: "plugin.wasm"))
        let manager = PluginManager(
            directory: root, approvals: PluginApprovalStore(defaults: defaults),
            projects: { projects.projects }, actions: { _ in .inert })
        await manager.reload()
        await manager.approve(try #require(manager.plugins.first))
        return (manager, {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        })
    }

    @MainActor
    @Test func reconcileFollowsTheProjectList() async throws {
        let projects = ProjectList([Self.project("a")])
        let (manager, cleanup) = try await approvedManager(projects: projects)
        defer { cleanup() }
        let first = try #require(manager.host(pluginID: "io.x.p", projectID: "a"))
        projects.projects = [Self.project("b")]
        await manager.reconcile()
        #expect(manager.hostsByKey.keys.map(\.projectID) == ["b"])
        #expect(first.state == .stopped)
        await manager.shutdown()
    }

    @MainActor
    @Test func disablingAPluginStopsItsHostsAndEnablingRestartsThem() async throws {
        let projects = ProjectList([Self.project("a")])
        let (manager, cleanup) = try await approvedManager(projects: projects)
        defer { cleanup() }
        let plugin = try #require(manager.plugins.first)
        await manager.setEnabled(plugin, false)
        #expect(manager.hostsByKey.isEmpty)
        #expect(!manager.isEnabled(plugin))
        await manager.reconcile()
        #expect(manager.hostsByKey.isEmpty, "reconcile must not restart a disabled plugin")
        await manager.setEnabled(plugin, true)
        #expect(manager.host(pluginID: "io.x.p", projectID: "a")?.state == .active)
        await manager.shutdown()
    }
```

- [ ] **Step 2: Run the tests and confirm they fail**

`-only-testing AlasTests/PluginManagerDiscoveryTests`. Expected: compile errors.

- [ ] **Step 3: Implement the disabled set**

In `PluginTrust.swift`, add to `PluginApprovalStore`:

```swift
    private static let disabledKey = "pluginDisabledIDs.v1"

    /// Disabling keeps the approval, so re-enabling needs no new prompt.
    func isDisabled(id: String) -> Bool {
        defaults.stringArray(forKey: Self.disabledKey)?.contains(id) == true
    }

    func setDisabled(id: String, _ disabled: Bool) {
        var ids = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
        if disabled { ids.insert(id) } else { ids.remove(id) }
        defaults.set(ids.sorted(), forKey: Self.disabledKey)
    }
```

- [ ] **Step 4: Implement the manager changes**

In `PluginManager.swift`:
- add `@ObservationIgnored private var tickTask: Task<Void, Never>?`;
- add the lookups and tick interval:

```swift
    func isEnabled(_ plugin: Plugin) -> Bool { !approvals.isDisabled(id: plugin.id) }

    func plugin(id: String) -> Plugin? { plugins.first { $0.id == id } }

    func host(pluginID: String, projectID: String) -> PluginHost? {
        hostsByKey[HostKey(pluginID: pluginID, projectID: projectID)]
    }

    static var tickInterval: Duration {
        #if DEBUG
        .milliseconds(200)  // 5 fps: unoptimized WasmKit is ~400x slower
        #else
        .milliseconds(66)   // 15 fps
        #endif
    }
```

- add the public operations, all serialised:

```swift
    func setEnabled(_ plugin: Plugin, _ enabled: Bool) async {
        await serialized {
            self.approvals.setDisabled(id: plugin.id, !enabled)
            if enabled { await self.start(plugin) } else { await self.stopHosts { $0.pluginID == plugin.id } }
        }
    }

    func revoke(_ plugin: Plugin) async {
        await serialized {
            self.approvals.revoke(id: plugin.id)
            await self.stopHosts { $0.pluginID == plugin.id }
        }
    }

    /// Starts hosts for projects added since the last pass and stops hosts whose project is gone.
    func reconcile() async {
        await serialized {
            let projectIDs = Set(self.projects().map(\.id))
            await self.stopHosts { !projectIDs.contains($0.projectID) }
            for plugin in self.plugins { await self.start(plugin) }
        }
    }

    /// Stops every loop and host. The manager is not reused afterwards.
    func shutdown() async {
        await serialized {
            self.snapshotTask?.cancel()
            self.tickTask?.cancel()
            await self.stopHosts { _ in true }
        }
    }

    private func stopHosts(where matches: (HostKey) -> Bool) async {
        for key in hostsByKey.keys.filter(matches) {
            await hostsByKey[key]?.deactivate()
            hostsByKey[key] = nil
            lastSnapshots[key] = nil
        }
    }
```

- change `start(_:)`'s first guard to also require enabled:

```swift
        guard isEnabled(plugin), let approval = approvals.approval(id: plugin.id, hash: plugin.hash) else { return }
```

- in `performReload`, replace the first four lines' teardown with `await stopHosts { _ in true }` (keeping `snapshotTask?.cancel()`), and after `startSnapshotLoop()` call `startTickLoop()`;
- snapshot loop body: `await self?.reconcile()` before `await self?.pushChangedSnapshots()`. Update the ponytail comment to say the loop also reconciles projects;
- the tick loop:

```swift
    // ponytail: one fixed-rate loop for all hosts; a host with no visible tab returns immediately.
    private func startTickLoop() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.fireTicks()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    private func fireTicks() {
        let now = ContinuousClock.now
        // Each host ticks independently, so one slow plugin cannot delay another's frames.
        for host in hostsByKey.values where host.isTicking {
            Task { await host.tick(at: now) }
        }
    }
```

- update the doc comment on `reload()`: remove "Projects added later need another reload (Debug-only for now)".

- [ ] **Step 5: Run the tests and confirm they pass**

`-only-testing AlasTests/PluginManagerDiscoveryTests`. Expected: all `✔`, including the existing two.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Plugins/PluginTrust.swift Alas/Sources/Plugins/PluginManager.swift AlasTests/PluginManagerDiscoveryTests.swift
git commit -m "feat(plugins): disable, revoke and reconcile plugin hosts, and drive the tick clock"
```

---

### Task 5: Plugins setting and `AppState` ownership

**Files:**
- Modify: `Alas/Sources/Persistence/AppConfig.swift`, `Alas/Sources/App/AppState.swift`, `Alas/Sources/Plugins/AppState+Plugins.swift`, `Alas/Sources/App/RootView.swift`, `Alas/Sources/Plugins/PluginsWindow.swift`

**Interfaces:**
- Consumes: `PluginManager.shutdown()` and `PluginHostActions.inert`; `activateHarnessSession(projectId:worktreeId:sessionId:)` (existing, `AppState.swift` ~line 7185); `agentSidebarRollup(for:)` (existing).
- Produces:
  - `AppConfig.pluginsEnabled: Bool` (default `false`);
  - `AppState.pluginManager: PluginManager?`;
  - `AppState.startPluginsIfEnabled() async` and `AppState.setPluginsEnabled(_:) async`.

There's no new test, because this is wiring that forwards to tested code. The check is a build.

- [ ] **Step 1: Add the config flag**

In `AppConfig.swift`, mirror `needsAttentionEnabled` in all four places:
- **Declaration** (after `needsAttentionEnabled`):
  ```swift
      /// Opt-in gate for WebAssembly plugins. Off: nothing is scanned, loaded or run.
      var pluginsEnabled: Bool = false
  ```
- **Default instance** (~line 592): add `pluginsEnabled: false,` after `needsAttentionEnabled: false,`.
- **Coding keys** (~line 688): add `pluginsEnabled,` after `needsAttentionEnabled,`.
- **Decoder** (~line 935):
  ```swift
          pluginsEnabled = (try? c.decode(Bool.self, forKey: .pluginsEnabled)) ?? false
  ```

- [ ] **Step 2: Store the manager on `AppState`**

In `AppState.swift`, next to `private(set) var workspaceRecoveryError` (~line 346):

```swift
    /// Exists only while `config.pluginsEnabled` is on.
    var pluginManager: PluginManager?
```

- [ ] **Step 3: Manager lifecycle and `focusSession`**

Replace `AppState+Plugins.swift` with:

```swift
import Foundation

extension AppState {
    func startPluginsIfEnabled() async {
        guard config.pluginsEnabled, pluginManager == nil else { return }
        let manager = PluginManager(
            projects: { [weak self] in self?.projects ?? [] },
            actions: { [weak self] project in self?.pluginHostActions(for: project) ?? .inert })
        pluginManager = manager
        await manager.reload()
    }

    func setPluginsEnabled(_ enabled: Bool) async {
        config.pluginsEnabled = enabled
        _ = saveConfig()
        if enabled {
            await startPluginsIfEnabled()
        } else if let manager = pluginManager {
            pluginManager = nil
            await manager.shutdown()
        }
    }

    /// Plugin actions scoped to `project`: a snapshot of its worktrees, and
    /// switching and focusing only within it.
    func pluginHostActions(for project: ProjectConfig) -> PluginHostActions {
        PluginHostActions(
            snapshot: { [weak self] in
                self?.pluginWorkspaceSnapshot(projectId: project.id) ?? PluginWorkspaceSnapshot(worktrees: [])
            },
            switchWorktree: { [weak self] id in
                guard let self,
                      self.projectsManager.worktreesByProject[project.id]?.contains(where: { $0.id == id }) == true
                else { return false }
                self.focusGlobalWorktree(id: id, projectId: project.id)
                return true
            },
            focusSession: { [weak self] id in
                guard let self else { return false }
                // Only sessions the snapshot exposes, so a plugin cannot reach another project's sessions.
                for worktree in self.projectsManager.worktreesByProject[project.id] ?? []
                where self.agentSidebarRollup(for: worktree).active.contains(where: {
                    PluginWorkspaceSnapshot.SessionInput(row: $0).id == id
                }) {
                    self.activateHarnessSession(projectId: project.id, worktreeId: worktree.id, sessionId: id)
                    return true
                }
                return false
            })
    }

    // pluginWorkspaceSnapshot(projectId:) unchanged
}
```

Keep the existing `pluginWorkspaceSnapshot(projectId:)` as it is.

- [ ] **Step 4: Start at launch**

In `RootView.swift`, in the launch `.task` (~line 119), directly after `state.reloadTabs()`:

```swift
                Task { await state.startPluginsIfEnabled() }
```

- [ ] **Step 5: Debug window reads the shared manager**

In `PluginsWindow.swift`, delete `makeManager` and the `manager` property from `PluginsWindowController`. Make `show(state:)` build the content from the state:

```swift
        win.contentView = NSHostingView(rootView: PluginsDebugRoot(state: state))
```

with:

```swift
struct PluginsDebugRoot: View {
    let state: AppState

    var body: some View {
        if let manager = state.pluginManager {
            PluginsView(manager: manager)
        } else {
            Text("Plugins are off. Turn them on in Settings → Advanced.")
                .frame(minWidth: 720, minHeight: 480)
        }
    }
}
```

Update the controller's doc comment: the window is only an inspector, and `AppState` owns the manager.

- [ ] **Step 6: Build**

Run the build-only command. Expected: `** BUILD SUCCEEDED **` in the log (`grep -E "BUILD (SUCCEEDED|FAILED)|error:" /tmp/alas-test.log`).

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Persistence/AppConfig.swift Alas/Sources/App/AppState.swift Alas/Sources/Plugins/AppState+Plugins.swift Alas/Sources/App/RootView.swift Alas/Sources/Plugins/PluginsWindow.swift
git commit -m "feat(plugins): own the plugin manager in AppState behind a plugins setting"
```

---

### Task 6: Settings: Plugins toggle, pane and approval sheet

**Files:**
- Create: `Alas/Sources/Plugins/PluginsPane.swift`
- Modify: `Alas/Sources/Settings/AdvancedPane.swift`, `Alas/Sources/Settings/SettingsNavView.swift`, `Alas/Sources/Settings/SettingsWindow.swift`, `Alas/Sources/Plugins/PluginsWindow.swift`, `AlasTests/SettingsSectionTests.swift` (only if it enumerates every section)

**Interfaces:**
- Consumes: `AppState.setPluginsEnabled(_:)` and `pluginManager`; on the manager, `approve`, `setEnabled`, `revoke`, `restart`, `reload`, `hosts(for:)`, `isApproved` and `isEnabled`.
- Produces:
  - `SettingsSection.plugins`;
  - `SettingsSection.visibleSections(showsDebug:showsPlugins:)`, with `showsPlugins` defaulting to `false`;
  - `PluginHostState.displayText: String`.

There are no view tests (per policy). The check is a build plus the existing `SettingsSectionTests`.

- [ ] **Step 1: Advanced toggle**

In `AdvancedPane.swift`, inside `SettingsGroup(title: "Experimental")`, after the "Needs attention" row:

```swift
                    SettingsRow(
                        name: "Plugins",
                        desc: "Runs approved WebAssembly plugins from ~/Library/Application Support/Alas/Plugins."
                    ) {
                        AlasToggle(on: Binding(
                            get: { state.config.pluginsEnabled },
                            set: { enabled in Task { @MainActor in await state.setPluginsEnabled(enabled) } }
                        ))
                    }
```

- [ ] **Step 2: Section and routing**

In `SettingsNavView.swift`:
- add `plugins` to the `SettingsSection` case list;
- label `"Plugins"`, icon `"puzzlepiece.extension"`;
- change `visibleSections`:

```swift
    static func visibleSections(showsDebug: Bool, showsPlugins: Bool = false) -> [SettingsSection] {
        SettingsSection.allCases
            .filter { (showsDebug || $0 != .debug) && (showsPlugins || $0 != .plugins) }
            .sorted(by: { … unchanged … })
    }
```

- give `SettingsNavView` a `var showsPlugins: Bool = false` and pass it through at line ~90.

In `SettingsWindow.swift`:
- pass `showsPlugins: state.pluginManager != nil` to `SettingsNavView`;
- add `case .plugins: PluginsPane(state: state)` to the switch;
- in `.onAppear`, after the debug fallback, add `if state.pluginManager == nil, section == .plugins { section = .agents }`.

If `SettingsSectionTests` asserts the exact label list, the default `showsPlugins: false` keeps it unchanged. Run it to confirm.

- [ ] **Step 3: Host state text**

Move `PluginHostRow.label(_:)` out of the `#if DEBUG` file into `PluginsPane.swift` as:

```swift
extension PluginHostState {
    var displayText: String {
        switch self {
        case .loaded: "Loaded"
        case .activating: "Starting"
        case .active: "Active"
        case .deactivating: "Stopping"
        case .stopped: "Stopped"
        case .failed(let reason): "Stopped: \(reason)"
        }
    }
}
```

In `PluginsWindow.swift`, replace `Self.label(host.state)` with `host.state.displayText` and delete `label(_:)`.

- [ ] **Step 4: The pane**

Create `Alas/Sources/Plugins/PluginsPane.swift`:

```swift
import AppKit
import SwiftUI

struct PluginsPane: View {
    let state: AppState
    @Environment(\.theme) var theme
    @State private var approving: PluginManager.Plugin?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Plugins").font(.system(size: 18, weight: .semibold))
                Text("WebAssembly plugins run sandboxed, with only the capabilities you approve.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)
                if let manager = state.pluginManager {
                    content(manager)
                }
            }
            .padding(24)
        }
        .sheet(item: $approving) { plugin in
            PluginApprovalSheet(plugin: plugin) { approved in
                approving = nil
                if approved, let manager = state.pluginManager {
                    Task { await manager.approve(plugin) }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ manager: PluginManager) -> some View {
        HStack {
            AlasButton(title: "Reveal Plugins Folder", icon: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([manager.directory])
            }
            AlasButton(title: "Rescan", icon: "arrow.clockwise") { Task { await manager.reload() } }
        }
        .padding(.bottom, 12)
        if manager.plugins.isEmpty {
            Text("No plugins installed.").foregroundColor(theme.color("fg-dim"))
        }
        ForEach(manager.plugins) { plugin in
            SettingsGroup(title: "\(plugin.manifest.name) \(plugin.manifest.version)") {
                SettingsRow(name: plugin.id, desc: Self.status(manager, plugin)) {
                    if manager.isApproved(plugin) {
                        AlasToggle(on: Binding(
                            get: { manager.isEnabled(plugin) },
                            set: { enabled in Task { await manager.setEnabled(plugin, enabled) } }))
                        AlasButton(title: "Revoke Approval", style: .normal) { Task { await manager.revoke(plugin) } }
                    } else {
                        AlasButton(title: "Approve…", style: .normal) { approving = plugin }
                    }
                }
                ForEach(manager.hosts(for: plugin), id: \.key) { entry in
                    PluginHostLogRow(host: entry.host) { Task { await manager.restart(entry.key) } }
                }
            }
        }
        if !manager.invalid.isEmpty {
            SettingsGroup(title: "Not loaded") {
                ForEach(manager.invalid) { entry in
                    Text("\(entry.folder.lastPathComponent): \(entry.reason)")
                        .font(.system(size: 11.5)).textSelection(.enabled)
                }
            }
        }
    }

    private static func status(_ manager: PluginManager, _ plugin: PluginManager.Plugin) -> String {
        if !manager.isApproved(plugin) { return "Not approved" }
        if !manager.isEnabled(plugin) { return "Disabled" }
        return "Enabled"
    }
}

private struct PluginHostLogRow: View {
    let host: PluginHost
    let restart: () -> Void

    var body: some View {
        DisclosureGroup {
            ForEach(Array(host.log.enumerated()), id: \.offset) { _, entry in
                Text("[\(entry.level)] \(entry.message)")
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
        } label: {
            HStack {
                Text("\(host.project.name): \(host.state.displayText)")
                Spacer()
                AlasButton(title: "Restart", style: .normal, action: restart)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PluginApprovalSheet: View {
    let plugin: PluginManager.Plugin
    let finish: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Approve \(plugin.manifest.name)?").font(.headline)
            Text("\(plugin.id) · version \(plugin.manifest.version)").font(.caption).foregroundStyle(.secondary)
            if plugin.manifest.capabilities.isEmpty {
                Text("It requests no capabilities.")
            } else {
                Text("It will be able to:")
                ForEach(plugin.manifest.capabilities, id: \.self) { Text("• \($0.summary)") }
            }
            Text("Changing the plugin's files requires approving it again.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { finish(false) }.keyboardShortcut(.cancelAction)
                Button("Approve") { finish(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
```

`PluginManager.Plugin` is already `Identifiable`, so `.sheet(item:)` works. If `AlasButton`'s icon names don't resolve, `Icon.symbol(for:)` passes unknown names through to SF Symbols, so `folder` and `arrow.clockwise` render as-is.

- [ ] **Step 5: Regenerate, build and test**

```bash
xcodegen
```

Then run `-only-testing AlasTests/SettingsSectionTests`. It builds the whole app, so it doubles as the build check. Expected: `✔` and no compile errors.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Plugins/PluginsPane.swift Alas/Sources/Plugins/PluginsWindow.swift Alas/Sources/Settings Alas.xcodeproj
git commit -m "feat(plugins): add the plugins setting and a Settings pane to approve and manage plugins"
```

---

### Task 7: Plugin center tab, View → Plugins menu, API 2 docs

**Files:**
- Create: `Alas/Sources/Plugins/PluginTabView.swift`, `AlasTests/PluginTabTests.swift`, `docs/plugins/api-v2.md`
- Modify: `Alas/Sources/Center/Tab.swift`, `Alas/Sources/Center/TabsManager.swift`, `Alas/Sources/Center/CenterPaneView.swift`, `Alas/Sources/Plugins/AppState+Plugins.swift`, `Alas/Sources/App/AlasApp.swift`, `docs/plugins/README.md`, `docs/plugins/getting-started.md`

**Interfaces:**
- Consumes:
  - from `PluginHost`: `frames`, `regions`, `setViewVisible`, `click` and `state`;
  - from `PluginManager`: `plugin(id:)`, `host(pluginID:projectID:)`, `isApproved`, `isEnabled` and `restart`;
  - `Worktree.projectId`;
  - `activateWorktreeCenterTab(worktreeId:tabId:)` (existing).
- Produces:
  - `Tab.plugin(PluginTabState)`;
  - `struct PluginTabState: Codable, Equatable, Identifiable { id, pluginID, contributionID, title }`;
  - `TabsManager.openOrFocusPluginTab(worktreeId:state:) -> Tab`;
  - on `AppState`: `pluginTabContributions() -> [PluginTabState]` and `openPluginTab(_:)`;
  - `enum PluginTabContent: Equatable { case unavailable, stopped(String), loading, canvas }` with `static func resolve(...)`;
  - `enum PluginCanvasLayout { static func scale(frame: CGSize, in: CGSize) -> Int }`.

- [ ] **Step 1: Write the failing tests**

Create `AlasTests/PluginTabTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import Alas

struct PluginTabTests {
    @Test(arguments: [
        (CGSize(width: 320, height: 180), CGSize(width: 1000, height: 600), 3),
        (CGSize(width: 320, height: 180), CGSize(width: 1000, height: 400), 2),
        (CGSize(width: 320, height: 180), CGSize(width: 200, height: 100), 1),
        (CGSize(width: 0, height: 0), CGSize(width: 200, height: 100), 1),
    ])
    func canvasScalesByTheLargestWholeFactorThatFits(frame: CGSize, view: CGSize, expected: Int) {
        #expect(PluginCanvasLayout.scale(frame: frame, in: view) == expected)
    }

    struct ContentCase: Sendable {
        var pluginsOn = true, found = true, approved = true, enabled = true
        var hostState: PluginHostState? = .active
        var hasFrame = true
        let expected: PluginTabContent
    }

    @Test(arguments: [
        ContentCase(expected: .canvas),
        ContentCase(pluginsOn: false, expected: .unavailable),
        ContentCase(found: false, hostState: nil, expected: .unavailable),
        ContentCase(approved: false, hostState: nil, expected: .unavailable),
        ContentCase(enabled: false, hostState: nil, expected: .unavailable),
        ContentCase(hostState: .failed("trap"), expected: .stopped("trap")),
        ContentCase(hostState: .activating, hasFrame: false, expected: .loading),
        ContentCase(hasFrame: false, expected: .loading),
        ContentCase(hostState: nil, hasFrame: false, expected: .loading),
    ])
    func placeholderFollowsPluginAndHostState(_ c: ContentCase) {
        #expect(PluginTabContent.resolve(
            pluginsOn: c.pluginsOn, found: c.found, approved: c.approved, enabled: c.enabled,
            hostState: c.hostState, hasFrame: c.hasFrame) == c.expected)
    }
}
```

- [ ] **Step 2: Add the tab case**

In `Tab.swift`:
- add `case plugin(PluginTabState)` after `runReport`;
- add `case .plugin(let s): return s.id` to `id`, `case .plugin(let s): return s.title` to `title`, and `case .plugin: return "puzzlepiece.extension"` to `iconName`;
- add the state type next to `RunReportTabState`:

```swift
/// A plugin's canvas tab. Restores even when the plugin is gone, showing a placeholder instead.
struct PluginTabState: Codable, Equatable, Identifiable {
    let id: TabID
    let pluginID: String
    let contributionID: String
    /// Last known title, so a placeholder can name a plugin that was removed.
    var title: String

    init(pluginID: String, contributionID: String, title: String) {
        self.pluginID = pluginID
        self.contributionID = contributionID
        self.title = title
        id = "plugin:\(pluginID)/\(contributionID)"
    }
}
```

In `TabsManager.swift`, after `openOrFocusRunReport`:

```swift
    @discardableResult
    func openOrFocusPluginTab(worktreeId: String, state: PluginTabState) -> Tab {
        if let existing = tabs(forWorktree: worktreeId).first(where: { $0.id == state.id }) {
            activate(worktreeId: worktreeId, tabId: state.id)
            return existing
        }
        let tab = Tab.plugin(state)
        append(tab, to: worktreeId)
        return tab
    }
```

In `CenterPaneView.swift`, next to `case .runReport` (~line 694):

```swift
                    case .plugin(let s):
                        PluginTabView(state: state, worktree: worktree, tab: s)
                            .id(s.id)
                            .onAppear { completeStartupRecoveryIfActive(s.id) }
```

The compiler lists any other exhaustive `switch` over `Tab`. Add `.plugin` to each one, following what `.runReport` does there.

- [ ] **Step 3: The view and its pure helpers**

Create `Alas/Sources/Plugins/PluginTabView.swift`:

```swift
import AppKit
import SwiftUI

enum PluginTabContent: Equatable {
    case unavailable
    case stopped(String)
    case loading
    case canvas

    static func resolve(
        pluginsOn: Bool, found: Bool, approved: Bool, enabled: Bool,
        hostState: PluginHostState?, hasFrame: Bool
    ) -> PluginTabContent {
        guard pluginsOn, found, approved, enabled else { return .unavailable }
        if case .failed(let reason) = hostState { return .stopped(reason) }
        return hostState == .active && hasFrame ? .canvas : .loading
    }
}

enum PluginCanvasLayout {
    /// Largest whole-number scale at which the frame fits, never below 1 (a larger frame is clipped).
    static func scale(frame: CGSize, in view: CGSize) -> Int {
        guard frame.width > 0, frame.height > 0 else { return 1 }
        return max(1, Int(min(view.width / frame.width, view.height / frame.height)))
    }
}

extension PluginFrame {
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct PluginTabView: View {
    let state: AppState
    let worktree: Worktree
    let tab: PluginTabState
    @Environment(\.theme) var theme

    var body: some View {
        let manager = state.pluginManager
        let plugin = manager?.plugin(id: tab.pluginID)
        let host = manager?.host(pluginID: tab.pluginID, projectID: worktree.projectId)
        let tabIndex = plugin?.manifest.tabs.firstIndex { $0.id == tab.contributionID }
        let content = PluginTabContent.resolve(
            pluginsOn: manager != nil,
            found: plugin != nil && tabIndex != nil,
            approved: plugin.map { manager?.isApproved($0) == true } ?? false,
            enabled: plugin.map { manager?.isEnabled($0) == true } ?? false,
            hostState: host?.state,
            hasFrame: tabIndex.flatMap { host?.frames[$0] } != nil)
        ZStack {
            theme.color("bg-1")
            switch content {
            case .canvas:
                if let host, let tabIndex { PluginCanvasView(host: host, tabIndex: tabIndex) }
            case .loading:
                ProgressView().controlSize(.small)
            case .stopped(let reason):
                placeholder("\(tab.title) stopped: \(reason)", button: "Restart") {
                    guard let manager else { return }
                    Task { await manager.restart(.init(pluginID: tab.pluginID, projectID: worktree.projectId)) }
                }
            case .unavailable:
                placeholder("\(tab.title) isn't available", button: "Open Plugin Settings") {
                    NotificationCenter.default.post(
                        name: .alasOpenSettings,
                        object: manager == nil ? SettingsSection.debug : SettingsSection.plugins)
                }
            }
        }
        // The host ticks only while a canvas for it is on screen.
        .background(PluginVisibilityReporter(host: content == .canvas || content == .loading ? host : nil))
    }

    private func placeholder(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(text).foregroundColor(theme.color("fg-dim")).multilineTextAlignment(.center)
            AlasButton(title: button, style: .normal, action: action)
        }
        .padding(24)
    }
}

private struct PluginCanvasView: View {
    let host: PluginHost
    let tabIndex: Int

    var body: some View {
        GeometryReader { geometry in
            if let frame = host.frames[tabIndex], let image = frame.cgImage {
                let size = CGSize(width: frame.width, height: frame.height)
                let scale = CGFloat(PluginCanvasLayout.scale(frame: size, in: geometry.size))
                let origin = CGPoint(
                    x: ((geometry.size.width - size.width * scale) / 2).rounded(.down),
                    y: ((geometry.size.height - size.height * scale) / 2).rounded(.down))
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: size.width * scale, height: size.height * scale)
                        .offset(x: origin.x, y: origin.y)
                        .accessibilityHidden(true)
                    ForEach(host.regions[tabIndex] ?? [], id: \.id) { region in
                        Button { Task { await host.click(tab: tabIndex, region: region.id) } } label: {
                            Color.clear.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: CGFloat(region.rect[2]) * scale, height: CGFloat(region.rect[3]) * scale)
                        .offset(x: origin.x + CGFloat(region.rect[0]) * scale, y: origin.y + CGFloat(region.rect[1]) * scale)
                        .help(region.label)
                        .accessibilityLabel(region.label)
                        .pointerStyle(.link)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
            }
        }
    }
}

/// Reports the tab as visible while it is in a window that is not occluded.
private struct PluginVisibilityReporter: NSViewRepresentable {
    let host: PluginHost?

    func makeNSView(context: Context) -> ReporterView { ReporterView() }

    func updateNSView(_ view: ReporterView, context: Context) { view.host = host }

    static func dismantleNSView(_ view: ReporterView, coordinator: ()) { view.host = nil }

    @MainActor
    final class ReporterView: NSView {
        private var reported: PluginHost?
        private var observer: NSObjectProtocol?

        var host: PluginHost? { didSet { update() } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = window.map {
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: $0, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
            }
            update()
        }

        private func update() {
            let visible = window?.occlusionState.contains(.visible) == true ? host : nil
            guard visible !== reported else { return }
            reported?.setViewVisible(false)
            visible?.setViewVisible(true)
            reported = visible
        }
    }
}
```

`PluginManager.HostKey` has a memberwise init (`pluginID:projectID:`). If `.init(...)` doesn't infer, write `PluginManager.HostKey(pluginID:projectID:)`. If `.pointerStyle(.link)` isn't available on the deployment target, use `.onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }`.

- [ ] **Step 4: Contributions and menu**

Append to `AppState+Plugins.swift`:

```swift
extension AppState {
    /// Tab contributions of plugins running for the selected worktree's project.
    func pluginTabContributions() -> [PluginTabState] {
        guard let manager = pluginManager,
              let worktreeId = selectedWorktreeId,
              let projectId = worktree(withId: worktreeId)?.projectId
        else { return [] }
        return manager.plugins
            .filter { manager.host(pluginID: $0.id, projectID: projectId)?.state == .active }
            .flatMap { plugin in
                plugin.manifest.tabs.map {
                    PluginTabState(pluginID: plugin.id, contributionID: $0.id, title: $0.title)
                }
            }
    }

    func openPluginTab(_ tab: PluginTabState) {
        guard let worktreeId = selectedWorktreeId else { return }
        tabs.openOrFocusPluginTab(worktreeId: worktreeId, state: tab)
        activateWorktreeCenterTab(worktreeId: worktreeId, tabId: tab.id)
    }
}
```

In `AlasApp.swift`, inside the second `CommandGroup(after: .toolbar)` (the font-size one, ~line 467), before the font buttons:

```swift
            let pluginTabs = state.pluginTabContributions()
            if !pluginTabs.isEmpty {
                Menu("Plugins") {
                    ForEach(pluginTabs) { tab in
                        Button(tab.title) { state.openPluginTab(tab) }
                    }
                }
                Divider()
            }
```

- [ ] **Step 5: Write the API 2 docs**

Create `docs/plugins/api-v2.md`. Base the text on sections 2 and 4 of the spec, with this outline:
1. **What's new in API 2.** Declare `"api": 2`. API 1 plugins are unchanged.
2. **Manifest `contributes.tabs`.** Rules: at most 4, id charset, unique, title 1–40.
3. **The `session.focus` capability.**
4. **`alas.present(tab, ptr, len, width)`.** Pixel format and validation, the last frame per call wins, and frames from a call that fails are discarded.
5. **`tick {dt}`.** Rates, only while visible, dropped while busy, `dt: 0` on resume.
6. **`canvas/regions` and `canvas/click`.** Limits, truncation, and what makes regions malformed.
7. **`session/focus`.** Errors.
8. **Limits table.**

In `README.md`, link `api-v2.md` next to `api-v1.md`. In `getting-started.md`, replace the Debug → Plugins… steps with:
- turn on Settings → Advanced → Experimental → Plugins (the Advanced section shows when `~/.alas/.debug` exists);
- then Settings → Plugins → Approve…;
- keep Debug → Plugins… as the message inspector.

- [ ] **Step 6: Regenerate and test**

```bash
xcodegen
```

`-only-testing AlasTests/PluginTabTests`. Expected: all `✔`, and the app target compiles.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources AlasTests/PluginTabTests.swift Alas.xcodeproj docs/plugins
git commit -m "feat(plugins): render plugin canvas tabs with accessible regions"
```

---

### Task 8: `alas-plugin` Rust SDK, `hello-workspace` on it, CI

**Files:**
- Create: `plugins/alas-plugin/Cargo.toml`, `plugins/alas-plugin/src/lib.rs`, `plugins/alas-plugin/.gitignore` (`/target`), `plugins/alas-plugin/Cargo.lock`
- Modify: `plugins/samples/hello-workspace/{Cargo.toml,src/lib.rs,Cargo.lock}`, `.github/workflows/build.yml`, `docs/plugins/writing-plugins.md`

**Interfaces:**
- Produces (Rust, crate `alas_plugin`):
  - data types `Snapshot { worktrees: Vec<Worktree> }`, `Worktree { id, branch, current, dirty: Option<Dirty>, sessions: Vec<Session> }`, `Dirty { files: u32, conflicts: u32 }`, `Session { id, agent, title, state, plan: Option<Plan> }`, `Plan { completed: u32, total: u32 }`, `Region { id: String, label: String, rect: [i32; 4] }` and `RpcError { code: i64, message: String }`;
  - `enum Event { Activate { project_id, project_name, grants: Vec<String> }, Deactivate, WorkspaceChanged(Snapshot), Tick { dt: u32 }, Click { tab: u32, region: String }, Reply { id: i64, result: Result<Value, RpcError> } }`;
  - `trait Plugin: Default { fn handle(&mut self, event: Event); }`;
  - functions `log(level, message)`, `request(method, params) -> i64`, `present(tab, pixels, width)`, `set_regions(tab, &[Region])` and `dispatch(&mut impl Plugin, &[u8])`;
  - the macro `export_plugin!(Type)`;
  - `test_host::{take_sent, take_frames}` on non-wasm targets.

- [ ] **Step 1: Write the crate with its tests**

`plugins/alas-plugin/Cargo.toml`:

```toml
[package]
name = "alas-plugin"
version = "0.1.0"
edition = "2021"
publish = false

# Standalone: not part of any parent workspace.
[workspace]

[dependencies]
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

`plugins/alas-plugin/src/lib.rs`:

```rust
//! SDK for Alas plugins (API 1 and 2). Handles the ABI, JSON-RPC framing, the
//! activation handshake and request ids. On non-wasm targets the host imports are
//! replaced by an in-memory recorder (`test_host`) so plugins can be unit tested.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::cell::Cell;

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Snapshot {
    pub worktrees: Vec<Worktree>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Worktree {
    pub id: String,
    pub branch: String,
    pub current: bool,
    #[serde(default)]
    pub dirty: Option<Dirty>,
    pub sessions: Vec<Session>,
}

#[derive(Debug, Clone, Copy, PartialEq, Deserialize, Serialize)]
pub struct Dirty {
    pub files: u32,
    pub conflicts: u32,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Session {
    pub id: String,
    pub agent: String,
    pub title: String,
    pub state: String,
    #[serde(default)]
    pub plan: Option<Plan>,
}

#[derive(Debug, Clone, Copy, PartialEq, Deserialize, Serialize)]
pub struct Plan {
    pub completed: u32,
    pub total: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Region {
    pub id: String,
    pub label: String,
    pub rect: [i32; 4],
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Activate { project_id: String, project_name: String, grants: Vec<String> },
    Deactivate,
    WorkspaceChanged(Snapshot),
    Tick { dt: u32 },
    Click { tab: u32, region: String },
    Reply { id: i64, result: Result<Value, RpcError> },
}

pub trait Plugin: Default {
    fn handle(&mut self, event: Event);
}

#[cfg(target_arch = "wasm32")]
mod sys {
    #[link(wasm_import_module = "alas")]
    extern "C" {
        pub fn send(ptr: *const u8, len: usize);
        pub fn present(tab: u32, ptr: *const u8, len: usize, width: u32);
    }
}

/// Records what a plugin sends when it is compiled for the host, for tests.
#[cfg(not(target_arch = "wasm32"))]
pub mod test_host {
    use serde_json::Value;
    use std::cell::RefCell;

    thread_local! {
        pub(crate) static SENT: RefCell<Vec<Value>> = RefCell::new(Vec::new());
        pub(crate) static FRAMES: RefCell<Vec<(u32, u32, Vec<u8>)>> = RefCell::new(Vec::new());
    }

    pub fn take_sent() -> Vec<Value> {
        SENT.with(|sent| std::mem::take(&mut *sent.borrow_mut()))
    }

    /// `(tab, width, pixels)` for each `present` call.
    pub fn take_frames() -> Vec<(u32, u32, Vec<u8>)> {
        FRAMES.with(|frames| std::mem::take(&mut *frames.borrow_mut()))
    }
}

fn send(message: &Value) {
    #[cfg(target_arch = "wasm32")]
    {
        let text = message.to_string();
        unsafe { sys::send(text.as_ptr(), text.len()) }
    }
    #[cfg(not(target_arch = "wasm32"))]
    test_host::SENT.with(|sent| sent.borrow_mut().push(message.clone()));
}

pub fn log(level: &str, message: &str) {
    send(&json!({"jsonrpc": "2.0", "method": "log", "params": {"level": level, "message": message}}));
}

thread_local! {
    static NEXT_ID: Cell<i64> = const { Cell::new(1) };
}

/// Sends a request and returns its id. The reply arrives in a later call as `Event::Reply`.
pub fn request(method: &str, params: Value) -> i64 {
    let id = NEXT_ID.with(|next| {
        let id = next.get();
        next.set(id + 1);
        id
    });
    send(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
    id
}

/// Hands Alas one RGBA8 frame for tab `tab`. Alas copies it during this call.
pub fn present(tab: u32, pixels: &[u8], width: u32) {
    #[cfg(target_arch = "wasm32")]
    unsafe {
        sys::present(tab, pixels.as_ptr(), pixels.len(), width)
    }
    #[cfg(not(target_arch = "wasm32"))]
    test_host::FRAMES.with(|frames| frames.borrow_mut().push((tab, width, pixels.to_vec())));
}

pub fn set_regions(tab: u32, regions: &[Region]) {
    send(&json!({"jsonrpc": "2.0", "method": "canvas/regions", "params": {"tab": tab, "regions": regions}}));
}

/// Parses one incoming message and hands it to `plugin`. Activation is answered
/// before the plugin sees it, so a plugin cannot forget the handshake.
pub fn dispatch<P: Plugin>(plugin: &mut P, bytes: &[u8]) {
    let Ok(message) = serde_json::from_slice::<Value>(bytes) else { return };
    let params = &message["params"];
    let event = match message["method"].as_str() {
        Some("alas/activate") => {
            send(&json!({"jsonrpc": "2.0", "id": message["id"], "result": {}}));
            Event::Activate {
                project_id: params["project"]["id"].as_str().unwrap_or_default().to_string(),
                project_name: params["project"]["name"].as_str().unwrap_or_default().to_string(),
                grants: serde_json::from_value(params["grants"].clone()).unwrap_or_default(),
            }
        }
        Some("alas/deactivate") => Event::Deactivate,
        Some("workspace/changed") => match serde_json::from_value(params["snapshot"].clone()) {
            Ok(snapshot) => Event::WorkspaceChanged(snapshot),
            Err(_) => return,
        },
        Some("tick") => Event::Tick { dt: params["dt"].as_u64().unwrap_or(0) as u32 },
        Some("canvas/click") => Event::Click {
            tab: params["tab"].as_u64().unwrap_or(0) as u32,
            region: params["region"].as_str().unwrap_or_default().to_string(),
        },
        Some(_) => return,
        None => {
            let Some(id) = message["id"].as_i64() else { return };
            let result = match serde_json::from_value::<RpcError>(message["error"].clone()) {
                Ok(error) => Err(error),
                Err(_) => Ok(message["result"].clone()),
            };
            Event::Reply { id, result }
        }
    };
    plugin.handle(event);
}

#[doc(hidden)]
pub fn alloc(len: usize) -> *mut u8 {
    Box::into_raw(vec![0u8; len].into_boxed_slice()) as *mut u8
}

/// # Safety
/// `ptr`/`len` must come from `alloc`; Alas guarantees this.
#[doc(hidden)]
pub unsafe fn take(ptr: *mut u8, len: usize) -> Box<[u8]> {
    Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len))
}

/// Exports `alas_alloc` and `alas_handle` for a `Plugin` type.
#[macro_export]
macro_rules! export_plugin {
    ($plugin:ty) => {
        thread_local! {
            static ALAS_PLUGIN: ::std::cell::RefCell<$plugin> = ::std::cell::RefCell::new(<$plugin>::default());
        }

        #[no_mangle]
        pub extern "C" fn alas_alloc(len: usize) -> *mut u8 {
            $crate::alloc(len)
        }

        /// # Safety
        /// Called by Alas with a buffer from `alas_alloc`.
        #[no_mangle]
        pub unsafe extern "C" fn alas_handle(ptr: *mut u8, len: usize) {
            let bytes = $crate::take(ptr, len);
            ALAS_PLUGIN.with(|plugin| $crate::dispatch(&mut *plugin.borrow_mut(), &bytes));
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Recorder(Vec<Event>);

    impl Plugin for Recorder {
        fn handle(&mut self, event: Event) {
            self.0.push(event);
        }
    }

    fn feed(plugin: &mut Recorder, message: Value) {
        dispatch(plugin, message.to_string().as_bytes());
    }

    #[test]
    fn activation_is_answered_before_the_plugin_sees_it() {
        test_host::take_sent();
        let mut plugin = Recorder::default();
        feed(&mut plugin, json!({"jsonrpc":"2.0","id":0,"method":"alas/activate",
            "params":{"api":2,"project":{"id":"p","name":"Proj"},"grants":["workspace.read"]}}));
        assert_eq!(test_host::take_sent(), vec![json!({"jsonrpc":"2.0","id":0,"result":{}})]);
        assert_eq!(plugin.0, vec![Event::Activate {
            project_id: "p".into(), project_name: "Proj".into(), grants: vec!["workspace.read".into()],
        }]);
    }

    #[test]
    fn requests_get_increasing_ids_and_replies_carry_them_back() {
        test_host::take_sent();
        let first = request("workspace/snapshot", json!({}));
        let second = request("session/focus", json!({"id": "s"}));
        assert!(second > first);
        assert_eq!(test_host::take_sent()[1]["id"], json!(second));

        let mut plugin = Recorder::default();
        feed(&mut plugin, json!({"jsonrpc":"2.0","id":second,"error":{"code":-32003,"message":"unknown session s"}}));
        feed(&mut plugin, json!({"jsonrpc":"2.0","id":first,"result":{"ok":true}}));
        assert_eq!(plugin.0, vec![
            Event::Reply { id: second, result: Err(RpcError { code: -32003, message: "unknown session s".into() }) },
            Event::Reply { id: first, result: Ok(json!({"ok": true})) },
        ]);
    }

    #[test]
    fn canvas_events_and_snapshots_decode() {
        let mut plugin = Recorder::default();
        feed(&mut plugin, json!({"jsonrpc":"2.0","method":"tick","params":{"dt":66}}));
        feed(&mut plugin, json!({"jsonrpc":"2.0","method":"canvas/click","params":{"tab":0,"region":"r3"}}));
        feed(&mut plugin, json!({"jsonrpc":"2.0","method":"workspace/changed","params":{"snapshot":{"worktrees":[
            {"id":"w","branch":"main","current":true,"sessions":[{"id":"s","agent":"claude","title":"T","state":"running","plan":{"completed":1,"total":3}}]}
        ]}}}));
        assert_eq!(plugin.0[0], Event::Tick { dt: 66 });
        assert_eq!(plugin.0[1], Event::Click { tab: 0, region: "r3".into() });
        let Event::WorkspaceChanged(snapshot) = &plugin.0[2] else { panic!("expected a snapshot") };
        assert_eq!(snapshot.worktrees[0].dirty, None);
        assert_eq!(snapshot.worktrees[0].sessions[0].plan, Some(Plan { completed: 1, total: 3 }));
    }

    #[test]
    fn regions_encode_as_the_wire_shape() {
        test_host::take_sent();
        set_regions(0, &[Region { id: "r0".into(), label: "L".into(), rect: [1, 2, 3, 4] }]);
        assert_eq!(test_host::take_sent()[0]["params"],
            json!({"tab": 0, "regions": [{"id": "r0", "label": "L", "rect": [1, 2, 3, 4]}]}));
    }
}
```

- [ ] **Step 2: Run the tests**

```bash
cd plugins/alas-plugin && cargo +1.98.1 test && cd -
```

Expected: 4 passed. This also creates `Cargo.lock`.

- [ ] **Step 3: Move `hello-workspace` onto the SDK**

- In `plugins/samples/hello-workspace/Cargo.toml`, set the dependencies to `alas-plugin = { path = "../../alas-plugin" }` and `serde_json = "1"`.
- Replace `src/lib.rs`:

```rust
//! Minimal Alas plugin (API 1). Logs a summary of the project's worktrees and
//! agent sessions, and deliberately calls `worktree/switch` without the
//! capability to show the denial path.

use alas_plugin::{export_plugin, log, request, Event, Plugin, Snapshot};
use serde_json::json;

#[derive(Default)]
struct Hello {
    snapshot_request: i64,
    switch_request: i64,
}

fn summary(snapshot: &Snapshot) -> String {
    let sessions: Vec<_> = snapshot.worktrees.iter().flat_map(|w| &w.sessions).collect();
    let running = sessions.iter().filter(|s| s.state == "running").count();
    format!("{} worktrees, {} sessions ({} running)", snapshot.worktrees.len(), sessions.len(), running)
}

impl Plugin for Hello {
    fn handle(&mut self, event: Event) {
        match event {
            Event::Activate { project_name, .. } => {
                log("info", &format!("activated for {project_name}"));
                self.snapshot_request = request("workspace/snapshot", json!({}));
                self.switch_request = request("worktree/switch", json!({"id": "any"}));
            }
            Event::WorkspaceChanged(snapshot) => log("info", &format!("changed: {}", summary(&snapshot))),
            Event::Reply { id, result } if id == self.snapshot_request => {
                if let Some(snapshot) = result.ok().and_then(|v| serde_json::from_value(v["snapshot"].clone()).ok()) {
                    log("info", &format!("snapshot: {}", summary(&snapshot)));
                }
            }
            Event::Reply { id, result: Err(error), .. } if id == self.switch_request => {
                log("warn", &format!("worktree/switch replied {} {}", error.code, error.message));
            }
            _ => {}
        }
    }
}

export_plugin!(Hello);
```

- [ ] **Step 4: Check that `hello-workspace` still builds as an API 1 module**

```bash
cd plugins/samples/hello-workspace && cargo +1.98.1 build --release --target wasm32-unknown-unknown && \
  ! strings target/wasm32-unknown-unknown/release/hello_workspace.wasm | grep -qx present && echo "no present import" ; cd -
```

Expected: the build succeeds and prints `no present import`. If `present` shows up, the API 1 host would reject the module. Fix it by putting `present` behind a cargo feature `canvas` (off by default) in `alas-plugin`, and enabling that feature from `pixel-office`.

- [ ] **Step 5: Add the crate to CI**

In `.github/workflows/build.yml`, Rust test matrix (~line 673):

```yaml
          - project: plugins/alas-plugin
            toolchain: "1.98.1"
```

Add `'plugins/alas-plugin/Cargo.lock'` to the cache key's `hashFiles(...)` list (~line 691).

- [ ] **Step 6: Update the authoring docs**

In `docs/plugins/writing-plugins.md`, replace the hand-written ABI glue walkthrough with the SDK:
- the `alas-plugin` path dependency;
- `impl Plugin` and `export_plugin!`;
- `request` ids and matching `Event::Reply`;
- `present` and `set_regions` for API 2, pointing to `api-v2.md`.

Keep the raw ABI description in `api-v1.md` as the reference for other languages.

- [ ] **Step 7: Commit**

```bash
git add plugins/alas-plugin plugins/samples/hello-workspace .github/workflows/build.yml docs/plugins/writing-plugins.md
git commit -m "feat(plugins): add the alas-plugin Rust SDK and move the sample onto it"
```

---

### Task 9: `pixel-office` crate, asset pipeline, canvas primitives

**Files:**
- Create: `plugins/pixel-office/{Cargo.toml,.gitignore,plugin.json,build.rs,build.sh}`, `plugins/pixel-office/src/{lib.rs,sprites.rs,canvas.rs}`, `plugins/pixel-office/assets/palette.hex`, and placeholder PNGs (replaced in Task 10)
- Modify: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: the `alas-plugin` SDK (Task 8).
- Produces (Rust):
  - `sprites::{Sheet, PALETTE, CHARACTERS, FURNITURE, OVERLAYS, FONT}`, where `Sheet { width: usize, height: usize, pixels: &'static [u8] }` holds palette indices and 0 is transparent;
  - `canvas::{Rgba, Rect, Canvas}`, where `Rgba = [u8; 4]`, `Rect { x, y, w, h: i32 }` has `intersects` and `union`, and `Canvas { width, height, pixels: Vec<u8> }` has:
    - `new(w, h)`, `fill(Rect, Rgba)`, `copy_from(&Canvas, Rect)`;
    - `blit(&Sheet, src: Rect, dx, dy, palette: &[Rgba], flip: bool, dim: bool)`;
    - `text(x, y, &str, Rgba)` and `text_width(&str) -> i32`.

- [ ] **Step 1: Crate files**

`plugins/pixel-office/Cargo.toml`:

```toml
[package]
name = "pixel-office"
version = "0.1.0"
edition = "2021"
publish = false

# Standalone: not part of any parent workspace.
[workspace]

[lib]
crate-type = ["cdylib", "rlib"]

[dependencies]
alas-plugin = { path = "../alas-plugin" }
serde_json = "1"

[build-dependencies]
png = "0.17"

[profile.release]
opt-level = "s"
lto = true
strip = true
panic = "abort"
```

- `.gitignore`: `/target`.
- `plugin.json`:

```json
{
  "id": "io.nlopez.pixel-office",
  "name": "Pixel Office",
  "version": "0.1.0",
  "api": 2,
  "entry": "plugin.wasm",
  "capabilities": ["workspace.read", "worktree.switch", "session.focus"],
  "contributes": { "tabs": [{ "id": "office", "title": "Office" }] }
}
```

- `build.sh`: copy `plugins/samples/hello-workspace/build.sh` verbatim. It installs into `Plugins/pixel-office`.

`assets/palette.hex` has one `#rrggbb` per line, and line N (1-based) is palette index N. Use exactly these 24 entries. Indices 1–9 are the swappable ramps (skin, hair, shirt: dark, mid, light).

```
#8a5a3c
#c68a5e
#eab28c
#3a2a22
#5e4332
#86644a
#2a3a6e
#3e56a0
#6a86cc
#101018
#2b2b3a
#44445a
#6e6e86
#a4a4b8
#e8e8f0
#5a3a28
#8a5e3c
#b88a5a
#2e6e46
#4ea26a
#d23c3c
#f2c84a
#5ac8e6
#ffffff
```

- [ ] **Step 2: `build.rs`**

```rust
//! Decodes assets/*.png into palette-indexed bytes at build time, so the wasm
//! embeds raw sprites and never decodes PNG. Any colour not in palette.hex fails the build.

use std::{env, fs, path::Path};

fn main() {
    println!("cargo:rerun-if-changed=assets");
    let out = env::var("OUT_DIR").unwrap();
    let palette: Vec<[u8; 3]> = fs::read_to_string("assets/palette.hex")
        .unwrap()
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let hex = u32::from_str_radix(line.trim().trim_start_matches('#'), 16).unwrap();
            [(hex >> 16) as u8, (hex >> 8) as u8, hex as u8]
        })
        .collect();
    let mut rust = String::from("pub static PALETTE: [[u8; 4]; ");
    rust += &format!("{}] = [[0, 0, 0, 0]", palette.len() + 1);
    for [r, g, b] in &palette {
        rust += &format!(", [{r}, {g}, {b}, 255]");
    }
    rust += "];\n";
    for name in ["characters", "furniture", "overlays", "font"] {
        let file = fs::File::open(format!("assets/{name}.png")).unwrap();
        let mut decoder = png::Decoder::new(file);
        decoder.set_transformations(png::Transformations::normalize_to_color8() | png::Transformations::ALPHA);
        let mut reader = decoder.read_info().unwrap();
        let mut buf = vec![0; reader.output_buffer_size()];
        let info = reader.next_frame(&mut buf).unwrap();
        assert_eq!(info.color_type, png::ColorType::Rgba, "{name}.png must decode to RGBA");
        let indices: Vec<u8> = buf[..info.buffer_size()]
            .chunks(4)
            .enumerate()
            .map(|(i, px)| {
                if px[3] == 0 {
                    return 0;
                }
                let rgb = [px[0], px[1], px[2]];
                let index = palette.iter().position(|c| *c == rgb).unwrap_or_else(|| {
                    panic!("{name}.png ({}, {}) uses #{:02x}{:02x}{:02x}, not in palette.hex",
                        i as u32 % info.width, i as u32 / info.width, rgb[0], rgb[1], rgb[2])
                });
                index as u8 + 1
            })
            .collect();
        fs::write(Path::new(&out).join(format!("{name}.bin")), indices).unwrap();
        rust += &format!(
            "pub static {}: Sheet = Sheet {{ width: {}, height: {}, pixels: include_bytes!(concat!(env!(\"OUT_DIR\"), \"/{name}.bin\")) }};\n",
            name.to_uppercase(), info.width, info.height);
    }
    fs::write(Path::new(&out).join("sprites.rs"), rust).unwrap();
}
```

- [ ] **Step 3: Placeholder PNGs so the pipeline builds**

Generate transparent PNGs at the final sizes: characters 80×96, furniture 128×64, overlays 64×32, font 64×36. Task 10 replaces them. Use a stdlib-only script (not committed):

```bash
python3 - <<'EOF'
import struct, zlib
def png(path, w, h, rows):
    raw = b''.join(b'\x00' + bytes(r) for r in rows)
    def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
for name, w, h in [('characters', 80, 96), ('furniture', 128, 64), ('overlays', 64, 32), ('font', 64, 36)]:
    png(f'plugins/pixel-office/assets/{name}.png', w, h, [[0] * (w * 4)] * h)
EOF
```

- [ ] **Step 4: `sprites.rs`, `canvas.rs` and the tests**

`src/sprites.rs`:

```rust
//! Sprite sheets decoded by build.rs. Pixels are palette indices; 0 is transparent.

pub struct Sheet {
    pub width: usize,
    pub height: usize,
    pub pixels: &'static [u8],
}

include!(concat!(env!("OUT_DIR"), "/sprites.rs"));
```

`src/canvas.rs`:

```rust
use crate::sprites::{Sheet, FONT};

pub type Rgba = [u8; 4];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub const fn new(x: i32, y: i32, w: i32, h: i32) -> Rect {
        Rect { x, y, w, h }
    }

    pub fn intersects(&self, other: &Rect) -> bool {
        self.x < other.x + other.w && other.x < self.x + self.w && self.y < other.y + other.h && other.y < self.y + self.h
    }
}

/// Glyphs are 4x6 cells (3 px wide plus 1 px spacing), ASCII 32..=126, 16 per row.
pub const GLYPH_W: i32 = 4;
pub const GLYPH_H: i32 = 6;

pub struct Canvas {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}

impl Canvas {
    pub fn new(width: usize, height: usize) -> Canvas {
        Canvas { width, height, pixels: vec![0; width * height * 4] }
    }

    /// Clipped to the canvas, so callers can draw partly off-screen.
    fn clip(&self, r: Rect) -> Option<(usize, usize, usize, usize)> {
        let x0 = r.x.max(0) as usize;
        let y0 = r.y.max(0) as usize;
        let x1 = ((r.x + r.w).max(0) as usize).min(self.width);
        let y1 = ((r.y + r.h).max(0) as usize).min(self.height);
        (x0 < x1 && y0 < y1).then_some((x0, y0, x1, y1))
    }

    fn put(&mut self, x: i32, y: i32, color: Rgba) {
        if x < 0 || y < 0 || x as usize >= self.width || y as usize >= self.height {
            return;
        }
        let i = (y as usize * self.width + x as usize) * 4;
        self.pixels[i..i + 4].copy_from_slice(&color);
    }

    pub fn fill(&mut self, r: Rect, color: Rgba) {
        let Some((x0, y0, x1, y1)) = self.clip(r) else { return };
        for y in y0..y1 {
            for x in x0..x1 {
                let i = (y * self.width + x) * 4;
                self.pixels[i..i + 4].copy_from_slice(&color);
            }
        }
    }

    /// Copies `r` from `src`, which must be the same size as `self`.
    pub fn copy_from(&mut self, src: &Canvas, r: Rect) {
        let Some((x0, y0, x1, y1)) = self.clip(r) else { return };
        for y in y0..y1 {
            let a = (y * self.width + x0) * 4;
            let b = (y * self.width + x1) * 4;
            self.pixels[a..b].copy_from_slice(&src.pixels[a..b]);
        }
    }

    /// Draws `src` from `sheet` at (dx, dy). `palette[index]` gives each colour; index 0 is skipped.
    /// `dim` halves brightness, for the `unknown` state.
    pub fn blit(&mut self, sheet: &Sheet, src: Rect, dx: i32, dy: i32, palette: &[Rgba], flip: bool, dim: bool) {
        for sy in 0..src.h {
            for sx in 0..src.w {
                let (px, py) = ((src.x + sx) as usize, (src.y + sy) as usize);
                if px >= sheet.width || py >= sheet.height {
                    continue;
                }
                let index = sheet.pixels[py * sheet.width + px] as usize;
                if index == 0 {
                    continue;
                }
                let mut color = palette[index];
                if dim {
                    color = [color[0] / 2, color[1] / 2, color[2] / 2, 255];
                }
                let x = if flip { dx + src.w - 1 - sx } else { dx + sx };
                self.put(x, dy + sy, color);
            }
        }
    }

    pub fn text(&mut self, x: i32, y: i32, text: &str, color: Rgba) {
        for (n, ch) in text.chars().enumerate() {
            let code = if (' '..='~').contains(&ch) { ch as i32 - 32 } else { '?' as i32 - 32 };
            let src = Rect::new((code % 16) * GLYPH_W, (code / 16) * GLYPH_H, GLYPH_W, GLYPH_H);
            let palette = [[0, 0, 0, 0], color];
            // Any non-transparent font pixel is "on".
            for sy in 0..GLYPH_H {
                for sx in 0..GLYPH_W {
                    let (px, py) = ((src.x + sx) as usize, (src.y + sy) as usize);
                    if FONT.pixels[py * FONT.width + px] != 0 {
                        self.put(x + n as i32 * GLYPH_W + sx, y + sy, palette[1]);
                    }
                }
            }
        }
    }
}

pub fn text_width(text: &str) -> i32 {
    text.chars().count() as i32 * GLYPH_W
}

#[cfg(test)]
mod tests {
    use super::*;

    static SHEET: Sheet = Sheet { width: 2, height: 1, pixels: &[1, 0] };
    const PALETTE: [Rgba; 2] = [[0, 0, 0, 0], [9, 9, 9, 255]];

    fn at(c: &Canvas, x: usize, y: usize) -> Rgba {
        let i = (y * c.width + x) * 4;
        c.pixels[i..i + 4].try_into().unwrap()
    }

    #[test]
    fn blit_skips_transparent_pixels_flips_and_clips() {
        let mut c = Canvas::new(3, 1);
        c.fill(Rect::new(0, 0, 3, 1), [1, 1, 1, 255]);
        c.blit(&SHEET, Rect::new(0, 0, 2, 1), 0, 0, &PALETTE, false, false);
        assert_eq!([at(&c, 0, 0), at(&c, 1, 0)], [[9, 9, 9, 255], [1, 1, 1, 255]]);
        c.blit(&SHEET, Rect::new(0, 0, 2, 1), 1, 0, &PALETTE, true, true);
        assert_eq!(at(&c, 2, 0), [4, 4, 4, 255]);
        c.blit(&SHEET, Rect::new(0, 0, 2, 1), -1, 5, &PALETTE, false, false); // fully off-canvas: no panic
    }

    #[test]
    fn copy_from_restores_only_the_rect() {
        let background = Canvas::new(4, 4);
        let mut frame = Canvas::new(4, 4);
        frame.fill(Rect::new(0, 0, 4, 4), [7, 7, 7, 255]);
        frame.copy_from(&background, Rect::new(-2, -2, 3, 3));
        assert_eq!(at(&frame, 0, 0), [0, 0, 0, 0]);
        assert_eq!(at(&frame, 1, 1), [7, 7, 7, 255]);
    }
}
```

`src/lib.rs` (grows in later tasks):

```rust
//! Pixel Office: one character per agent session, one desk per worktree.

pub mod canvas;
pub mod sprites;
```

- [ ] **Step 5: Run the tests**

```bash
cd plugins/pixel-office && cargo +1.98.1 test && cd -
```

Expected: 2 passed. This also creates `Cargo.lock`.

- [ ] **Step 6: Add the crate to CI**

In `build.yml`, add a matrix entry `project: plugins/pixel-office`, `toolchain: "1.98.1"`, and `'plugins/pixel-office/Cargo.lock'` to the cache key.

- [ ] **Step 7: Commit**

```bash
git add plugins/pixel-office .github/workflows/build.yml
git commit -m "feat(pixel-office): add the crate, asset pipeline and canvas primitives"
```

---

### Task 10: Pixel art

This is a creative task. The contract below is fixed, because later tasks address sprites by these exact rectangles. The pixels are original work drawn for this repo, using only `assets/palette.hex` colours (index 1–24) and full transparency. `build.rs` rejects anything else.

**Files:**
- Replace: `plugins/pixel-office/assets/{characters,furniture,overlays,font}.png`
- Create: `plugins/pixel-office/src/atlas.rs`, and add `pub mod atlas;` to `lib.rs`

**Interfaces:**
- Produces: `atlas.rs` constants (Rust `Rect`s), used by Tasks 13 and 14.

**Sheet layouts** (x, y, w, h in pixels):

| Sheet | Size | Contents |
|---|---|---|
| `characters.png` | 80×96 | 16×24 cells. Row 0 (y 0): walk down, 4 frames. Row 1 (y 24): walk up, 4 frames. Row 2 (y 48): walk right, 4 frames (left is drawn flipped). Row 3 (y 72): `sit` (x 0), `type0` (x 16), `type1` (x 32), `hand` (raised, facing viewer, x 48), `sleep` (lying, x 64). Skin uses indices 1–3, hair 4–6, shirt 7–9, everything else fixed colours. |
| `furniture.png` | 128×64 | Row 0 (16 high): `floor` (0,0,16,16), `wall` (16,0,16,16), `desk` (32,0,64,16) for a 4-seat pod, `chair` (96,0,16,16), `plant` (112,0,16,16). Row 1 (y 16): `monitor_off` (0,16,16,16), `monitor_on0` (16,16,16,16), `monitor_on1` (32,16,16,16), `lamp_off` (48,16,8,16), `lamp_on` (56,16,8,16), `couch` (64,16,32,16). Row 2 (y 32, 32 high): `coffee` (0,32,16,32), `cooler` (16,32,16,32), `door` (32,32,16,32), `sign` (48,32,32,16) as a blank board for "+N more". |
| `overlays.png` | 64×32 | `bubble_q` (0,0,16,16), `bubble_bang` (16,0,16,16), `bubble_bang_red` (32,0,16,16), `zz` (48,0,8,8), `warning` (56,0,8,8), `papers1` (0,16,16,16), `papers2` (16,16,16,16), `papers3` (32,16,16,16), `bar_frame` (48,16,16,4) (the plan bar is filled with colour index 20 in code). |
| `font.png` | 64×36 | 4×6 cells, 16 per row, ASCII 32–126 in order (6 rows). Glyphs are 3 px wide with the right column empty. Any non-transparent pixel is "on". |

- [ ] **Step 1: Write `atlas.rs`**

```rust
//! Sprite rectangles in the sheets under assets/. Keep in sync with the PNG layouts.
use crate::canvas::Rect;

pub const CHAR_W: i32 = 16;
pub const CHAR_H: i32 = 24;
pub const WALK_DOWN: i32 = 0;
pub const WALK_UP: i32 = 24;
pub const WALK_RIGHT: i32 = 48;
pub const SIT: Rect = Rect::new(0, 72, 16, 24);
pub const TYPE: [Rect; 2] = [Rect::new(16, 72, 16, 24), Rect::new(32, 72, 16, 24)];
pub const HAND: Rect = Rect::new(48, 72, 16, 24);
pub const SLEEP: Rect = Rect::new(64, 72, 16, 24);

pub const FLOOR: Rect = Rect::new(0, 0, 16, 16);
pub const WALL: Rect = Rect::new(16, 0, 16, 16);
pub const DESK: Rect = Rect::new(32, 0, 64, 16);
pub const CHAIR: Rect = Rect::new(96, 0, 16, 16);
pub const PLANT: Rect = Rect::new(112, 0, 16, 16);
pub const MONITOR_OFF: Rect = Rect::new(0, 16, 16, 16);
pub const MONITOR_ON: [Rect; 2] = [Rect::new(16, 16, 16, 16), Rect::new(32, 16, 16, 16)];
pub const LAMP_OFF: Rect = Rect::new(48, 16, 8, 16);
pub const LAMP_ON: Rect = Rect::new(56, 16, 8, 16);
pub const COUCH: Rect = Rect::new(64, 16, 32, 16);
pub const COFFEE: Rect = Rect::new(0, 32, 16, 32);
pub const COOLER: Rect = Rect::new(16, 32, 16, 32);
pub const DOOR: Rect = Rect::new(32, 32, 16, 32);
pub const SIGN: Rect = Rect::new(48, 32, 32, 16);

pub const BUBBLE_Q: Rect = Rect::new(0, 0, 16, 16);
pub const BUBBLE_BANG: [Rect; 2] = [Rect::new(16, 0, 16, 16), Rect::new(32, 0, 16, 16)];
pub const ZZ: Rect = Rect::new(48, 0, 8, 8);
pub const WARNING: Rect = Rect::new(56, 0, 8, 8);
pub const PAPERS: [Rect; 3] = [Rect::new(0, 16, 16, 16), Rect::new(16, 16, 16, 16), Rect::new(32, 16, 16, 16)];
pub const BAR_FRAME: Rect = Rect::new(48, 16, 16, 4);

/// Walk frame `n` (0..4) in the row at `row_y`.
pub fn walk(row_y: i32, n: i32) -> Rect {
    Rect::new(n * CHAR_W, row_y, CHAR_W, CHAR_H)
}

#[cfg(test)]
mod tests {
    use crate::sprites::{CHARACTERS, FONT, FURNITURE, OVERLAYS};

    #[test]
    fn sheets_have_the_documented_sizes() {
        assert_eq!((CHARACTERS.width, CHARACTERS.height), (80, 96));
        assert_eq!((FURNITURE.width, FURNITURE.height), (128, 64));
        assert_eq!((OVERLAYS.width, OVERLAYS.height), (64, 32));
        assert_eq!((FONT.width, FONT.height), (64, 36));
    }

    #[test]
    fn every_printable_glyph_and_character_frame_is_drawn() {
        for code in 33..127 {
            let (gx, gy) = (((code - 32) % 16) * 4, ((code - 32) / 16) * 6);
            let lit = (0..6).any(|y| (0..4).any(|x| FONT.pixels[(gy + y) * FONT.width + gx + x] != 0));
            assert!(lit, "glyph {:?} is empty", char::from(code as u8));
        }
        for (x, y) in (0..4).flat_map(|n| [(n * 16, 0), (n * 16, 24), (n * 16, 48)]).chain((0..5).map(|n| (n * 16, 72))) {
            let lit = (0..24).any(|dy| (0..16).any(|dx| CHARACTERS.pixels[(y + dy) * CHARACTERS.width + x + dx] != 0));
            assert!(lit, "character frame at ({x}, {y}) is empty");
        }
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

`cargo +1.98.1 test`. Expected: `every_printable_glyph_and_character_frame_is_drawn` fails on the blank placeholders.

- [ ] **Step 3: Draw the sheets**

Author each sheet at the exact size above. You can use an editor such as Aseprite, or write per-sheet text pixel maps (one character per palette index, with `.` for transparent) and convert them with a throwaway script based on Task 9's `png()` writer, mapping each character to its palette RGB. Don't commit the script or the text maps; the PNGs are the source of truth. Style rules:
- 1 px dark outlines (index 10), simple 3-tone shading from the ramps;
- characters readable at 1×: head about 8 px, visible arms for typing and hand-raised;
- `type0`/`type1` differ only in hand position;
- `hand` faces the viewer with one arm up;
- `sleep` is a lying pose that fits the couch seat.

- [ ] **Step 4: Run the tests and confirm they pass**

`cargo +1.98.1 test`. Expected: all pass, and the build script raises no palette panic.

- [ ] **Step 5: Commit**

```bash
git add plugins/pixel-office/assets plugins/pixel-office/src
git commit -m "feat(pixel-office): draw the office sprite sheets and bitmap font"
```

---

### Task 11: Character looks

**Files:**
- Create: `plugins/pixel-office/src/look.rs`, and add `pub mod look;` to `lib.rs`

**Interfaces:**
- Produces:
  - `look::hash(&str) -> u32` (FNV-1a);
  - `look::Look { palette: [Rgba; 25] }` via `look::for_session(session_id: &str, agent: &str) -> Look`, which is the base `PALETTE` with indices 1–9 swapped.

- [ ] **Step 1: Write the failing tests and the implementation**

`src/look.rs`:

```rust
use crate::canvas::Rgba;
use crate::sprites::PALETTE;

pub fn hash(text: &str) -> u32 {
    text.bytes().fold(0x811c9dc5u32, |h, b| (h ^ b as u32).wrapping_mul(0x01000193))
}

type Ramp = [Rgba; 3];

const SKIN: [Ramp; 4] = [
    [[138, 90, 60, 255], [198, 138, 94, 255], [234, 178, 140, 255]],
    [[92, 58, 38, 255], [140, 92, 60, 255], [182, 128, 90, 255]],
    [[168, 120, 88, 255], [222, 170, 132, 255], [246, 208, 176, 255]],
    [[60, 38, 26, 255], [100, 66, 44, 255], [140, 98, 68, 255]],
];

const HAIR: [Ramp; 6] = [
    [[58, 42, 34, 255], [94, 67, 50, 255], [134, 100, 74, 255]],
    [[20, 20, 28, 255], [44, 44, 58, 255], [70, 70, 90, 255]],
    [[150, 90, 30, 255], [200, 130, 50, 255], [236, 180, 90, 255]],
    [[170, 60, 40, 255], [210, 90, 60, 255], [240, 140, 100, 255]],
    [[150, 150, 160, 255], [196, 196, 206, 255], [232, 232, 240, 255]],
    [[70, 40, 90, 255], [110, 70, 140, 255], [150, 110, 190, 255]],
];

const SHIRTS: [Ramp; 7] = [
    [[168, 76, 36, 255], [218, 112, 60, 255], [244, 156, 104, 255]],  // orange
    [[36, 100, 60, 255], [60, 150, 90, 255], [110, 200, 130, 255]],   // green
    [[42, 58, 110, 255], [62, 86, 160, 255], [106, 134, 204, 255]],   // blue
    [[90, 50, 130, 255], [130, 80, 180, 255], [176, 130, 220, 255]],  // purple
    [[70, 70, 80, 255], [110, 110, 124, 255], [160, 160, 176, 255]],  // grey
    [[30, 110, 120, 255], [50, 160, 170, 255], [110, 210, 214, 255]], // teal
    [[150, 50, 90, 255], [210, 80, 130, 255], [240, 140, 180, 255]],  // pink
];

fn shirt_for(agent: &str) -> usize {
    match agent {
        "claude" => 0,
        "codex" => 1,
        "gemini" => 2,
        "copilot" => 3,
        "cursor" => 4,
        "opencode" => 5,
        "pi" => 6,
        other => hash(other) as usize % SHIRTS.len(),
    }
}

pub struct Look {
    pub palette: [Rgba; 25],
}

/// Same session, same look: skin and hair from the session id, shirt from the agent.
pub fn for_session(session_id: &str, agent: &str) -> Look {
    let h = hash(session_id);
    let mut palette = PALETTE;
    let ramps = [SKIN[h as usize % SKIN.len()], HAIR[(h >> 8) as usize % HAIR.len()], SHIRTS[shirt_for(agent)]];
    for (r, ramp) in ramps.iter().enumerate() {
        palette[1 + r * 3..4 + r * 3].copy_from_slice(ramp);
    }
    Look { palette }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn looks_are_stable_per_session_and_shirts_follow_the_agent() {
        assert_eq!(for_session("s1", "codex").palette, for_session("s1", "codex").palette);
        assert_eq!(for_session("a", "claude").palette[7..10], SHIRTS[0]);
        assert_eq!(for_session("b", "claude").palette[7..10], SHIRTS[0]);
        assert_eq!(for_session("a", "claude").palette[10..], PALETTE[10..], "fixed colours never change");
    }
}
```

If `PALETTE`'s length isn't 25 (24 colours plus transparent), fix `palette.hex` rather than the type.

- [ ] **Step 2: Run the tests**

`cargo +1.98.1 test`. Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add plugins/pixel-office/src
git commit -m "feat(pixel-office): give each session a stable look and each agent a shirt colour"
```

---

### Task 12: Room layout from a snapshot

**Files:**
- Create: `plugins/pixel-office/src/layout.rs`, and add `pub mod layout;` to `lib.rs`

**Interfaces:**
- Consumes: `alas_plugin::Snapshot`, `canvas::Rect`.
- Produces:
  - constants `ROOM_W = 320`, `BASE_H = 180`, `TOP = 64`, `ROW_H = 48`, `PODS_PER_ROW = 4`, `SEATS = 4`, `MAX_H = 1024`, `DOOR: (i32, i32) = (24, 56)`, `SIDE_X = 4`, `LOUNGE: [(i32, i32); 6]` and `COUCH_SPOTS: [(i32, i32); 2]`;
  - `Pod { worktree_id: String, branch: String, desk: Rect, seats: [(i32, i32); 4], seated: Vec<String>, overflow: usize, lamp_on: bool, papers: u8, warning: bool, files: Option<u32> }`;
  - `Layout { height: i32, pods: Vec<Pod>, hidden_worktrees: usize }`;
  - `layout(&Snapshot) -> Layout`, `max_pods() -> usize`, `aisle_y(y: i32) -> i32`, `papers_bucket(Option<Dirty>) -> u8`.

- [ ] **Step 1: Write the module with its tests**

```rust
//! Where everything sits. Pure function of the snapshot.

use crate::canvas::Rect;
use alas_plugin::{Dirty, Snapshot};

pub const ROOM_W: i32 = 320;
pub const BASE_H: i32 = 180;
/// Desk rows start below the wall (0..24) and the lounge strip (24..64).
pub const TOP: i32 = 64;
pub const ROW_H: i32 = 48;
pub const PODS_PER_ROW: usize = 4;
pub const SEATS: usize = 4;
pub const MAX_H: i32 = 1024;
pub const BOTTOM_MARGIN: i32 = 12;
/// Where characters enter and leave (in front of the door, top-left).
pub const DOOR: (i32, i32) = (24, 56);
/// The corridor along the left wall joining the lounge and every desk row.
pub const SIDE_X: i32 = 4;
/// Standing/sitting spots in the lounge strip: coffee machine, water cooler, window.
pub const LOUNGE: [(i32, i32); 6] = [(96, 56), (112, 56), (176, 56), (192, 56), (256, 56), (272, 56)];
/// Couch seats, where sleepers go.
pub const COUCH_SPOTS: [(i32, i32); 2] = [(216, 52), (232, 52)];

#[derive(Debug, Clone, PartialEq)]
pub struct Pod {
    pub worktree_id: String,
    pub branch: String,
    pub desk: Rect,
    /// Top-left of each seated character (16x24).
    pub seats: [(i32, i32); SEATS],
    pub seated: Vec<String>,
    pub overflow: usize,
    pub lamp_on: bool,
    pub papers: u8,
    pub warning: bool,
    pub files: Option<u32>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Layout {
    pub height: i32,
    pub pods: Vec<Pod>,
    pub hidden_worktrees: usize,
}

pub fn max_pods() -> usize {
    ((MAX_H - TOP - BOTTOM_MARGIN) / ROW_H) as usize * PODS_PER_ROW
}

pub fn papers_bucket(dirty: Option<Dirty>) -> u8 {
    match dirty.map(|d| d.files) {
        None | Some(0) => 0,
        Some(1..=5) => 1,
        Some(6..=20) => 2,
        Some(_) => 3,
    }
}

/// The walking lane of the row containing `y`: just below its desks, or the lounge strip.
pub fn aisle_y(y: i32) -> i32 {
    if y < TOP { DOOR.1 } else { TOP + (y - TOP) / ROW_H * ROW_H + 40 }
}

pub fn layout(snapshot: &Snapshot) -> Layout {
    let shown = snapshot.worktrees.len().min(max_pods());
    let rows = shown.div_ceil(PODS_PER_ROW) as i32;
    let pods = snapshot.worktrees[..shown]
        .iter()
        .enumerate()
        .map(|(i, worktree)| {
            let x = (i % PODS_PER_ROW) as i32 * (ROOM_W / PODS_PER_ROW as i32);
            let y = TOP + (i / PODS_PER_ROW) as i32 * ROW_H;
            let desk = Rect::new(x + 8, y + 16, 64, 16);
            let seats = [0, 1, 2, 3].map(|s| (desk.x + s * 16, y));
            Pod {
                worktree_id: worktree.id.clone(),
                branch: worktree.branch.clone(),
                desk,
                seats,
                seated: worktree.sessions.iter().take(SEATS).map(|s| s.id.clone()).collect(),
                overflow: worktree.sessions.len().saturating_sub(SEATS),
                lamp_on: worktree.current,
                papers: papers_bucket(worktree.dirty),
                warning: worktree.dirty.is_some_and(|d| d.conflicts > 0),
                files: worktree.dirty.map(|d| d.files),
            }
        })
        .collect();
    Layout {
        height: BASE_H.max(TOP + rows * ROW_H + BOTTOM_MARGIN).min(MAX_H),
        pods,
        hidden_worktrees: snapshot.worktrees.len() - shown,
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use alas_plugin::{Session, Worktree};

    pub(crate) fn snapshot(sessions_per_worktree: &[usize]) -> Snapshot {
        Snapshot {
            worktrees: sessions_per_worktree
                .iter()
                .enumerate()
                .map(|(w, &n)| Worktree {
                    id: format!("w{w}"),
                    branch: format!("b{w}"),
                    current: w == 0,
                    dirty: None,
                    sessions: (0..n)
                        .map(|s| Session {
                            id: format!("w{w}s{s}"),
                            agent: "claude".into(),
                            title: format!("T{s}"),
                            state: "running".into(),
                            plan: None,
                        })
                        .collect(),
                })
                .collect(),
        }
    }

    #[test]
    fn pods_fill_rows_of_four_and_the_room_grows_downward() {
        assert_eq!(layout(&snapshot(&[0; 5])).height, BASE_H);
        let nine = layout(&snapshot(&[0; 9]));
        assert_eq!(nine.height, TOP + 3 * ROW_H + BOTTOM_MARGIN);
        assert_eq!(nine.pods[4].desk.y, TOP + ROW_H + 16);
        assert!(nine.pods[0].lamp_on && !nine.pods[1].lamp_on);
    }

    #[test]
    fn a_pod_seats_four_and_counts_the_rest() {
        let pod = &layout(&snapshot(&[6])).pods[0];
        assert_eq!(pod.seated.len(), 4);
        assert_eq!(pod.overflow, 2);
    }

    /// Review focus 5.
    #[test]
    fn overflowing_worktrees_are_summarised_and_height_is_capped() {
        let big = layout(&snapshot(&vec![0; max_pods() + 4]));
        assert_eq!(big.pods.len(), max_pods());
        assert_eq!(big.hidden_worktrees, 4);
        assert!(big.height <= MAX_H);
    }

    #[test]
    fn paper_piles_step_with_dirty_files() {
        let bucket = |files| papers_bucket(Some(Dirty { files, conflicts: 0 }));
        assert_eq!([papers_bucket(None), bucket(0), bucket(5), bucket(6), bucket(20), bucket(21)], [0, 0, 1, 2, 2, 3]);
    }
}
```

- [ ] **Step 2: Run the tests**

`cargo +1.98.1 test`. Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add plugins/pixel-office/src
git commit -m "feat(pixel-office): lay out desks per worktree from the snapshot"
```

---

### Task 13: Character simulation

**Files:**
- Create: `plugins/pixel-office/src/sim.rs`, and add `pub mod sim;` to `lib.rs`

**Interfaces:**
- Consumes: `layout::{Layout, DOOR, SIDE_X, LOUNGE, COUCH_SPOTS, aisle_y}`, `look::hash`, `alas_plugin::Snapshot`.
- Produces:
  - `Mood { Working, Waiting, Permission, Idle, Unknown }` with `Mood::from_state(&str)` and `Mood::words() -> &str`;
  - `Activity { Walking, Seated, Lounging, Sleeping }`;
  - `Character { session_id, agent, title, mood, plan: Option<Plan>, x: f32, y: f32, activity, facing_left: bool, walk_ms: u32, leaving: bool, … }`;
  - `World { characters: Vec<Character>, clock_ms: u64 }` with `sync(&mut self, &Snapshot, &Layout)` and `step(&mut self, dt_ms: u32, &Layout)`;
  - constants `WALK_SPEED = 32.0` px/s and `SLEEP_AFTER_MS = 300_000`.

- [ ] **Step 1: Write the module with its tests**

```rust
//! Who is where. Deterministic given the snapshot sequence and tick deltas.

use crate::layout::{aisle_y, Layout, COUCH_SPOTS, DOOR, LOUNGE, SIDE_X};
use crate::look::hash;
use alas_plugin::{Plan, Snapshot};

pub const WALK_SPEED: f32 = 32.0;
pub const SLEEP_AFTER_MS: u32 = 300_000;
const DWELL_MIN_MS: u32 = 8_000;
const DWELL_MAX_MS: u32 = 20_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mood {
    Working,
    Waiting,
    Permission,
    Idle,
    Unknown,
}

impl Mood {
    pub fn from_state(state: &str) -> Mood {
        match state {
            "running" => Mood::Working,
            "awaiting_input" => Mood::Waiting,
            "permission_request" => Mood::Permission,
            "idle" => Mood::Idle,
            _ => Mood::Unknown,
        }
    }

    pub fn words(self) -> &'static str {
        match self {
            Mood::Working => "working",
            Mood::Waiting => "awaiting input",
            Mood::Permission => "needs permission",
            Mood::Idle => "idle",
            Mood::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Activity {
    Walking,
    Seated,
    Lounging,
    Sleeping,
}

#[derive(Debug, Clone)]
pub struct Character {
    pub session_id: String,
    pub agent: String,
    pub title: String,
    pub mood: Mood,
    pub plan: Option<Plan>,
    pub x: f32,
    pub y: f32,
    pub activity: Activity,
    pub facing_left: bool,
    /// -1 walking up, 1 walking down, 0 walking sideways; picks the walk row.
    pub vertical: i8,
    /// Drives walk and typing frames.
    pub walk_ms: u32,
    pub leaving: bool,
    seat: (i32, i32),
    path: Vec<(f32, f32)>,
    /// What to become on arrival.
    arrive_as: Activity,
    idle_ms: u32,
    dwell_ms: u32,
    rng: u32,
}

impl Character {
    fn next_random(&mut self) -> u32 {
        // xorshift32; seeded from the session id so routines are reproducible.
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 17;
        self.rng ^= self.rng << 5;
        self.rng
    }

    fn dwell(&mut self) -> u32 {
        DWELL_MIN_MS + self.next_random() % (DWELL_MAX_MS - DWELL_MIN_MS)
    }

    /// Door -> corridor -> row aisle -> target, as straight segments.
    fn walk_to(&mut self, target: (i32, i32), arrive_as: Activity) {
        let (tx, ty) = (target.0 as f32, target.1 as f32);
        let here = aisle_y(self.y as i32) as f32;
        let there = aisle_y(target.1) as f32;
        self.path = if here == there {
            vec![(self.x, here), (tx, there), (tx, ty)]
        } else {
            vec![(self.x, here), (SIDE_X as f32, here), (SIDE_X as f32, there), (tx, there), (tx, ty)]
        };
        self.activity = Activity::Walking;
        self.arrive_as = arrive_as;
    }

    fn wants_seat(&self) -> bool {
        self.mood != Mood::Idle
    }
}

#[derive(Default)]
pub struct World {
    pub characters: Vec<Character>,
    pub clock_ms: u64,
}

impl World {
    /// Adds arrivals, sends departures to the door, and re-routes anyone whose mood or seat changed.
    pub fn sync(&mut self, snapshot: &Snapshot, layout: &Layout) {
        for pod in &layout.pods {
            let worktree = snapshot.worktrees.iter().find(|w| w.id == pod.worktree_id).unwrap();
            for (seat_index, session_id) in pod.seated.iter().enumerate() {
                let session = worktree.sessions.iter().find(|s| &s.id == session_id).unwrap();
                let seat = pod.seats[seat_index];
                let mood = Mood::from_state(&session.state);
                match self.characters.iter_mut().find(|c| &c.session_id == session_id && !c.leaving) {
                    Some(c) => {
                        c.title = session.title.clone();
                        c.plan = session.plan;
                        if c.mood != mood || c.seat != seat {
                            if mood != Mood::Idle {
                                c.idle_ms = 0;
                            }
                            c.mood = mood;
                            c.seat = seat;
                            reroute(c);
                        }
                    }
                    None => {
                        let mut c = Character {
                            session_id: session_id.clone(),
                            agent: session.agent.clone(),
                            title: session.title.clone(),
                            mood,
                            plan: session.plan,
                            x: DOOR.0 as f32,
                            y: DOOR.1 as f32,
                            activity: Activity::Walking,
                            facing_left: false,
                            vertical: 0,
                            walk_ms: 0,
                            leaving: false,
                            seat,
                            path: Vec::new(),
                            arrive_as: Activity::Seated,
                            idle_ms: 0,
                            dwell_ms: 0,
                            rng: hash(session_id) | 1,
                        };
                        c.walk_to(seat, Activity::Seated);
                        self.characters.push(c);
                    }
                }
            }
        }
        let present: Vec<&String> = layout.pods.iter().flat_map(|p| &p.seated).collect();
        for c in self.characters.iter_mut().filter(|c| !c.leaving && !present.contains(&&c.session_id)) {
            c.leaving = true;
            // Any non-walking arrival state works: `step` drops leavers once they stop walking.
            c.walk_to(DOOR, Activity::Seated);
        }
    }

    /// `_layout` is unused today; it is part of the signature so seats can move without an API change.
    pub fn step(&mut self, dt_ms: u32, _layout: &Layout) {
        self.clock_ms += dt_ms as u64;
        for c in &mut self.characters {
            c.walk_ms = c.walk_ms.wrapping_add(dt_ms);
            if c.mood == Mood::Idle && !c.leaving {
                c.idle_ms = c.idle_ms.saturating_add(dt_ms);
            }
            advance(c, dt_ms);
            if c.activity == Activity::Walking {
                continue;
            }
            if c.mood == Mood::Idle && !c.leaving {
                if c.idle_ms >= SLEEP_AFTER_MS && c.activity != Activity::Sleeping {
                    let spot = COUCH_SPOTS[(c.next_random() as usize) % COUCH_SPOTS.len()];
                    c.walk_to(spot, Activity::Sleeping);
                    continue;
                }
                if c.activity == Activity::Sleeping {
                    continue;
                }
                c.dwell_ms = c.dwell_ms.saturating_sub(dt_ms);
                if c.dwell_ms == 0 {
                    if c.activity == Activity::Lounging && c.next_random() % 2 == 0 {
                        let seat = c.seat;
                        c.walk_to(seat, Activity::Seated);
                    } else {
                        let spot = LOUNGE[(c.next_random() as usize) % LOUNGE.len()];
                        c.walk_to(spot, Activity::Lounging);
                    }
                }
            }
        }
        self.characters.retain(|c| !(c.leaving && c.activity != Activity::Walking));
    }
}

fn reroute(c: &mut Character) {
    if c.wants_seat() {
        let seat = c.seat;
        c.walk_to(seat, Activity::Seated);
    } else {
        // Newly idle: stay put for one dwell, then start wandering.
        c.dwell_ms = c.dwell();
        if c.activity == Activity::Walking {
            let seat = c.seat;
            c.walk_to(seat, Activity::Seated);
        }
    }
}

fn advance(c: &mut Character, dt_ms: u32) {
    let mut budget = WALK_SPEED * dt_ms as f32 / 1000.0;
    while budget > 0.0 {
        let Some(&(tx, ty)) = c.path.first() else { break };
        let (dx, dy) = (tx - c.x, ty - c.y);
        let distance = (dx * dx + dy * dy).sqrt();
        if dx != 0.0 {
            c.facing_left = dx < 0.0;
        }
        c.vertical = if dx.abs() >= dy.abs() { 0 } else if dy < 0.0 { -1 } else { 1 };
        if distance <= budget {
            (c.x, c.y) = (tx, ty);
            budget -= distance;
            c.path.remove(0);
        } else {
            c.x += dx / distance * budget;
            c.y += dy / distance * budget;
            budget = 0.0;
        }
    }
    if c.path.is_empty() && c.activity == Activity::Walking {
        c.activity = c.arrive_as;
        if c.activity == Activity::Lounging || (c.activity == Activity::Seated && c.mood == Mood::Idle) {
            c.dwell_ms = c.dwell();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::{layout, tests::snapshot};

    fn settle(world: &mut World, l: &Layout, ms: u32) {
        for _ in 0..ms / 100 {
            world.step(100, l);
        }
    }

    fn with_state(mut s: Snapshot, state: &str) -> Snapshot {
        s.worktrees[0].sessions[0].state = state.into();
        s
    }

    #[test]
    fn a_new_session_walks_in_from_the_door_and_sits_down() {
        let s = snapshot(&[1]);
        let l = layout(&s);
        let mut world = World::default();
        world.sync(&s, &l);
        let c = &world.characters[0];
        assert_eq!((c.x, c.y, c.activity), (DOOR.0 as f32, DOOR.1 as f32, Activity::Walking));
        settle(&mut world, &l, 20_000);
        let c = &world.characters[0];
        assert_eq!(c.activity, Activity::Seated);
        assert_eq!((c.x as i32, c.y as i32), l.pods[0].seats[0]);
    }

    #[test]
    fn busy_moods_stay_seated_and_idle_wanders_to_the_lounge() {
        for (state, busy) in [("running", true), ("awaiting_input", true), ("permission_request", true), ("unknown", true), ("idle", false)] {
            let s = with_state(snapshot(&[1]), state);
            let l = layout(&s);
            let mut world = World::default();
            world.sync(&s, &l);
            settle(&mut world, &l, 20_000); // walk in from the door
            let mut seen = Vec::new();
            for _ in 0..600 {
                world.step(100, &l); // one more minute
                seen.push(world.characters[0].activity);
            }
            if busy {
                assert!(seen.iter().all(|a| *a == Activity::Seated), "{state} left its seat");
            } else {
                assert!(seen.contains(&Activity::Lounging), "idle never reached the lounge");
                assert!(!seen.contains(&Activity::Sleeping), "idle for a minute should not sleep yet");
            }
        }
    }

    #[test]
    fn five_idle_minutes_end_asleep_on_the_couch() {
        let s = with_state(snapshot(&[1]), "idle");
        let l = layout(&s);
        let mut world = World::default();
        world.sync(&s, &l);
        settle(&mut world, &l, SLEEP_AFTER_MS + 30_000);
        let c = &world.characters[0];
        assert_eq!(c.activity, Activity::Sleeping);
        assert!(COUCH_SPOTS.contains(&(c.x as i32, c.y as i32)));
        // Waking: any busy state sends it back to the desk.
        let busy = snapshot(&[1]);
        world.sync(&busy, &l);
        settle(&mut world, &l, 30_000);
        assert_eq!(world.characters[0].activity, Activity::Seated);
    }

    #[test]
    fn an_ended_session_walks_out_and_disappears() {
        let s = snapshot(&[1]);
        let l = layout(&s);
        let mut world = World::default();
        world.sync(&s, &l);
        settle(&mut world, &l, 20_000);
        let empty = snapshot(&[0]);
        let l2 = layout(&empty);
        world.sync(&empty, &l2);
        assert!(world.characters[0].leaving);
        settle(&mut world, &l2, 30_000);
        assert!(world.characters.is_empty());
    }
}
```

- [ ] **Step 2: Run the tests**

`cargo +1.98.1 test`. Expected: pass. If a timing-based assertion fails, fix the simulation, not the test durations. The test durations assume 32 px/s over at most about 400 px of path (about 13 s).

- [ ] **Step 3: Commit**

```bash
git add plugins/pixel-office/src
git commit -m "feat(pixel-office): simulate characters walking, working, lounging and sleeping"
```

---

### Task 14: Rendering, regions and the plugin entry point

**Files:**
- Create: `plugins/pixel-office/src/render.rs`
- Modify: `plugins/pixel-office/src/lib.rs`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `render::Renderer` with `render(&mut self, &World, &Layout) -> &Canvas`;
  - `render::regions(&World, &Layout) -> (Vec<Region>, Vec<Target>)` and `enum Target { Session(String), Worktree(String) }`;
  - `Office: alas_plugin::Plugin`, plus `export_plugin!(Office)`.

- [ ] **Step 1: Write the renderer with its tests**

`src/render.rs`:

```rust
//! Background layer (room, desks, labels) cached and rebuilt only when the layout's
//! look changes; each frame restores the background under last frame's sprites and
//! draws them again. Must be pixel-identical to a full redraw.

use crate::atlas::*;
use crate::canvas::{text_width, Canvas, Rect, Rgba};
use crate::layout::{Layout, COUCH_SPOTS, DOOR, LOUNGE, ROOM_W};
use crate::look;
use crate::sim::{Activity, Mood, World};
use crate::sprites::{Sheet, CHARACTERS, FURNITURE, OVERLAYS, PALETTE};
use alas_plugin::Region;

const LABEL: Rgba = [232, 232, 240, 255];
const BAR_FILL: usize = 20;

pub struct Renderer {
    background: Canvas,
    frame: Canvas,
    background_key: Option<String>,
    previous: Vec<Rect>,
}

impl Default for Renderer {
    fn default() -> Self {
        Renderer { background: Canvas::new(0, 0), frame: Canvas::new(0, 0), background_key: None, previous: Vec::new() }
    }
}

fn draw(canvas: &mut Canvas, sheet: &Sheet, src: Rect, x: i32, y: i32) -> Rect {
    canvas.blit(sheet, src, x, y, &PALETTE, false, false);
    Rect::new(x, y, src.w, src.h)
}

/// Everything the background depends on, so any change rebuilds it.
fn background_key(layout: &Layout) -> String {
    let pods: Vec<String> = layout
        .pods
        .iter()
        .map(|p| format!("{}|{}|{}|{}|{}", p.branch, p.lamp_on, p.papers, p.warning, p.overflow))
        .collect();
    format!("{}#{}#{}", layout.height, layout.hidden_worktrees, pods.join(";"))
}

fn draw_background(layout: &Layout) -> Canvas {
    let mut c = Canvas::new(ROOM_W as usize, layout.height as usize);
    for y in (0..layout.height).step_by(16) {
        for x in (0..ROOM_W).step_by(16) {
            draw(&mut c, &FURNITURE, if y < 24 { WALL } else { FLOOR }, x, y);
        }
    }
    draw(&mut c, &FURNITURE, DOOR, DOOR.0 - 8, 8);
    draw(&mut c, &FURNITURE, COFFEE, LOUNGE[0].0 - 16, 16);
    draw(&mut c, &FURNITURE, COOLER, LOUNGE[2].0 - 16, 16);
    draw(&mut c, &FURNITURE, COUCH, COUCH_SPOTS[0].0, 36);
    draw(&mut c, &FURNITURE, PLANT, ROOM_W - 20, 8);
    for pod in &layout.pods {
        for &(sx, sy) in &pod.seats {
            draw(&mut c, &FURNITURE, CHAIR, sx, sy + 10);
        }
        draw(&mut c, &FURNITURE, DESK, pod.desk.x, pod.desk.y);
        draw(&mut c, &FURNITURE, if pod.lamp_on { LAMP_ON } else { LAMP_OFF }, pod.desk.x + pod.desk.w - 2, pod.desk.y - 12);
        if pod.papers > 0 {
            draw(&mut c, &OVERLAYS, PAPERS[pod.papers as usize - 1], pod.desk.x + pod.desk.w - 18, pod.desk.y - 6);
        }
        if pod.warning {
            draw(&mut c, &OVERLAYS, WARNING, pod.desk.x - 6, pod.desk.y);
        }
        let mut label = pod.branch.clone();
        let max = pod.desk.w + 8;
        while text_width(&label) > max && label.chars().count() > 1 {
            label.pop();
            if text_width(&label) + 4 <= max {
                label.push('~'); // the 4x6 font has no ellipsis; '~' marks truncation
                break;
            }
        }
        c.text(pod.desk.x - 4, pod.desk.y + 18, &label, LABEL);
        if pod.overflow > 0 {
            c.text(pod.desk.x + pod.desk.w - 12, pod.desk.y + 4, &format!("+{}", pod.overflow), LABEL);
        }
    }
    if layout.hidden_worktrees > 0 {
        draw(&mut c, &FURNITURE, SIGN, DOOR.0 + 12, 4);
        c.text(DOOR.0 + 14, 9, &format!("+{} more", layout.hidden_worktrees), LABEL);
    }
    c
}

impl Renderer {
    pub fn render(&mut self, world: &World, layout: &Layout) -> &Canvas {
        let key = background_key(layout);
        if self.background_key.as_ref() != Some(&key) {
            self.background = draw_background(layout);
            self.frame = Canvas::new(self.background.width, self.background.height);
            self.frame.pixels.copy_from_slice(&self.background.pixels);
            self.background_key = Some(key);
        } else {
            for r in std::mem::take(&mut self.previous) {
                self.frame.copy_from(&self.background, r);
            }
        }
        self.previous = draw_sprites(&mut self.frame, world, layout);
        &self.frame
    }
}

/// Draws the dynamic layer and returns every rect it touched.
fn draw_sprites(c: &mut Canvas, world: &World, layout: &Layout) -> Vec<Rect> {
    let mut touched = Vec::new();
    let flicker = (world.clock_ms / 250 % 2) as usize;
    for pod in &layout.pods {
        for (i, id) in pod.seated.iter().enumerate() {
            let working = world.characters.iter().any(|ch| &ch.session_id == id && ch.mood == Mood::Working && ch.activity == Activity::Seated);
            let (sx, _) = pod.seats[i];
            let src = if working { MONITOR_ON[flicker] } else { MONITOR_OFF };
            touched.push(draw(c, &FURNITURE, src, sx, pod.desk.y - 10));
        }
    }
    let mut order: Vec<_> = world.characters.iter().collect();
    order.sort_by_key(|ch| (ch.y as i32, ch.session_id.clone()));
    for ch in order {
        let (x, y) = (ch.x.round() as i32, ch.y.round() as i32);
        let frame = (ch.walk_ms / 150 % 4) as i32;
        let src = match (ch.activity, ch.mood) {
            (Activity::Walking, _) => walk([WALK_UP, WALK_RIGHT, WALK_DOWN][(ch.vertical + 1) as usize], frame),
            (Activity::Sleeping, _) => SLEEP,
            (Activity::Seated, Mood::Working) => TYPE[(ch.walk_ms / 200 % 2) as usize],
            (Activity::Seated, Mood::Waiting | Mood::Permission) => HAND,
            _ => SIT,
        };
        let palette = look::for_session(&ch.session_id, &ch.agent).palette;
        c.blit(&CHARACTERS, src, x, y, &palette, ch.facing_left, ch.mood == Mood::Unknown);
        touched.push(Rect::new(x, y, CHAR_W, CHAR_H));
        let bob = (world.clock_ms / 400 % 2) as i32;
        let overlay = match (ch.activity, ch.mood) {
            (Activity::Seated, Mood::Waiting) => Some(BUBBLE_Q),
            (Activity::Seated, Mood::Permission) => Some(BUBBLE_BANG[(world.clock_ms / 300 % 2) as usize]),
            (Activity::Sleeping, _) => Some(ZZ),
            _ => None,
        };
        if let Some(src) = overlay {
            touched.push(draw(c, &OVERLAYS, src, x + 8, y - 14 - bob));
        }
        if let (Activity::Seated, Mood::Working, Some(plan)) = (ch.activity, ch.mood, ch.plan) {
            if plan.total > 0 {
                let r = draw(c, &OVERLAYS, BAR_FRAME, x, y - 6);
                let filled = (14 * plan.completed.min(plan.total) / plan.total) as i32;
                c.fill(Rect::new(x + 1, y - 5, filled, 2), PALETTE[BAR_FILL]);
                touched.push(r);
            }
        }
    }
    touched
}

pub enum Target {
    Session(String),
    Worktree(String),
}

/// Region ids are short indexes ("r0", "r1", …) because Alas bounds ids to 64 bytes and
/// worktree ids can be long; `Target` at the same index says what a click means.
pub fn regions(world: &World, layout: &Layout) -> (Vec<Region>, Vec<Target>) {
    let mut regions = Vec::new();
    let mut targets = Vec::new();
    for ch in world.characters.iter().filter(|c| !c.leaving) {
        regions.push(Region {
            id: format!("r{}", regions.len()),
            label: format!("{}: {}, {}", ch.agent, ch.title, ch.mood.words()),
            rect: [ch.x.round() as i32, ch.y.round() as i32, CHAR_W, CHAR_H],
        });
        targets.push(Target::Session(ch.session_id.clone()));
    }
    for pod in &layout.pods {
        let mut label = format!("Worktree {}", pod.branch);
        if let Some(files) = pod.files {
            label += &format!(", {files} changed files");
        }
        if pod.warning {
            label += ", conflicts";
        }
        regions.push(Region {
            id: format!("r{}", regions.len()),
            label,
            rect: [pod.desk.x, pod.desk.y, pod.desk.w, pod.desk.h],
        });
        targets.push(Target::Worktree(pod.worktree_id.clone()));
    }
    (regions, targets)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::{layout, tests::snapshot};

    #[test]
    fn incremental_frames_match_a_full_redraw() {
        let mut s = snapshot(&[2, 1, 0, 3, 1]);
        s.worktrees[0].sessions[1].state = "idle".into();
        s.worktrees[1].sessions[0].state = "awaiting_input".into();
        s.worktrees[3].sessions[2].state = "permission_request".into();
        let l = layout(&s);
        let mut world = World::default();
        world.sync(&s, &l);
        let mut incremental = Renderer::default();
        for step in 0..400 {
            world.step(66, &l);
            if step == 200 {
                s.worktrees[0].sessions.pop();
                world.sync(&s, &layout(&s));
            }
            let l = layout(&s);
            let got = incremental.render(&world, &l).pixels.clone();
            let expected = Renderer::default().render(&world, &l).pixels.clone();
            assert!(got == expected, "frame {step} differs from a full redraw");
        }
    }

    #[test]
    fn regions_label_characters_and_desks() {
        let s = snapshot(&[1]);
        let l = layout(&s);
        let mut world = World::default();
        world.sync(&s, &l);
        let (regions, targets) = regions(&world, &l);
        assert_eq!(regions[0].label, "claude: T0, working");
        assert!(matches!(&targets[0], Target::Session(id) if id == "w0s0"));
        assert_eq!(regions[1].label, "Worktree b0");
        assert!(matches!(&targets[1], Target::Worktree(id) if id == "w0"));
    }
}
```

- [ ] **Step 2: Wire the plugin**

Replace `src/lib.rs`:

```rust
//! Pixel Office: one character per agent session, one desk per worktree.

pub mod atlas;
pub mod canvas;
pub mod layout;
pub mod look;
pub mod render;
pub mod sim;
pub mod sprites;

use alas_plugin::{export_plugin, log, present, request, set_regions, Event, Plugin, Region, Snapshot};
use layout::Layout;
use render::{Renderer, Target};
use serde_json::json;
use sim::World;

#[derive(Default)]
pub struct Office {
    layout: Option<Layout>,
    world: World,
    renderer: Renderer,
    snapshot_request: i64,
    regions: Vec<Region>,
    targets: Vec<Target>,
}

impl Office {
    fn apply(&mut self, snapshot: Snapshot) {
        let layout = layout::layout(&snapshot);
        self.world.sync(&snapshot, &layout);
        self.layout = Some(layout);
    }
}

impl Plugin for Office {
    fn handle(&mut self, event: Event) {
        match event {
            Event::Activate { .. } => self.snapshot_request = request("workspace/snapshot", json!({})),
            Event::WorkspaceChanged(snapshot) => self.apply(snapshot),
            Event::Reply { id, result: Ok(value) } if id == self.snapshot_request => {
                if let Ok(snapshot) = serde_json::from_value(value["snapshot"].clone()) {
                    self.apply(snapshot);
                }
            }
            // Review focus 4: e.g. a session that ended between the snapshot and the click.
            Event::Reply { result: Err(error), .. } => log("warn", &format!("request failed: {} {}", error.code, error.message)),
            Event::Tick { dt } => {
                let Some(layout) = &self.layout else { return };
                self.world.step(dt, layout);
                let frame = self.renderer.render(&self.world, layout);
                present(0, &frame.pixels, frame.width as u32);
                let (regions, targets) = render::regions(&self.world, layout);
                if regions != self.regions {
                    set_regions(0, &regions);
                    self.regions = regions;
                }
                self.targets = targets;
            }
            Event::Click { region, .. } => {
                let Some(index) = region.strip_prefix('r').and_then(|n| n.parse::<usize>().ok()) else { return };
                match self.targets.get(index) {
                    Some(Target::Session(id)) => { request("session/focus", json!({"id": id})); }
                    Some(Target::Worktree(id)) => { request("worktree/switch", json!({"id": id})); }
                    None => {}
                }
            }
            _ => {}
        }
    }
}

export_plugin!(Office);

#[cfg(test)]
mod tests {
    use super::*;
    use alas_plugin::{dispatch, test_host};

    fn feed(office: &mut Office, message: serde_json::Value) {
        dispatch(office, message.to_string().as_bytes());
    }

    #[test]
    fn ticks_present_a_frame_and_clicks_focus_the_session() {
        test_host::take_sent();
        test_host::take_frames();
        let mut office = Office::default();
        feed(&mut office, json!({"jsonrpc":"2.0","method":"workspace/changed","params":{"snapshot":{"worktrees":[
            {"id":"w","branch":"main","current":true,"sessions":[{"id":"s","agent":"claude","title":"T","state":"running"}]}]}}}));
        feed(&mut office, json!({"jsonrpc":"2.0","method":"tick","params":{"dt":66}}));
        let frames = test_host::take_frames();
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].1, layout::ROOM_W as u32);
        feed(&mut office, json!({"jsonrpc":"2.0","method":"canvas/click","params":{"tab":0,"region":"r0"}}));
        let sent = test_host::take_sent();
        assert!(sent.iter().any(|m| m["method"] == "canvas/regions"));
        assert!(sent.iter().any(|m| m["method"] == "session/focus" && m["params"]["id"] == "s"));
    }

    /// Review focus 4 (plugin side).
    #[test]
    fn an_error_reply_is_logged_and_ignored() {
        test_host::take_sent();
        let mut office = Office::default();
        feed(&mut office, json!({"jsonrpc":"2.0","id":7,"error":{"code":-32003,"message":"unknown session s"}}));
        let sent = test_host::take_sent();
        assert_eq!(sent[0]["params"]["level"], "warn");
    }
}
```

- [ ] **Step 3: Run the tests and check the wasm size**

```bash
cd plugins/pixel-office && cargo +1.98.1 test && \
  PATH="$(dirname "$(rustup which cargo)"):$PATH" cargo build --release --target wasm32-unknown-unknown && \
  ls -l target/wasm32-unknown-unknown/release/pixel_office.wasm ; cd -
```

Expected: all tests pass and the wasm builds. Note its size in the PR description.

- [ ] **Step 4: Commit**

```bash
git add plugins/pixel-office
git commit -m "feat(pixel-office): render the office, expose regions and handle clicks"
```

---

### Task 15: End-to-end manual check and docs sweep

**Files:**
- Modify: `docs/plugins/getting-started.md` (add Pixel Office install), `plugins/pixel-office/README.md` (create: build, install, what the characters mean)

- [ ] **Step 1: Build and install**

```bash
plugins/pixel-office/build.sh
plugins/samples/hello-workspace/build.sh
```

Then build and launch a Debug Alas using the `run` skill or the repo's usual launch path. Never `pkill` the Alas binary.

- [ ] **Step 2: Walk the exit condition**

Record pass or fail for each line in the PR description:
1. Settings → Advanced → Experimental → Plugins on. The Settings → Plugins section appears, listing Pixel Office and Hello Workspace as "Not approved".
2. Approve… shows the three capability lines for Pixel Office. Approve it, and the status becomes "Enabled".
3. View → Plugins → Office opens the tab, and the room shows desks for the project's worktrees.
4. Start an agent session. A character walks in and types. A permission prompt shows the red "!", and waiting for input shows "?".
5. Clicking a character focuses its session tab, and clicking a desk switches worktree. With VoiceOver on, regions read as buttons with their labels.
6. Quit and relaunch. The Office tab restores and renders.
7. Disable Pixel Office in Settings. The tab shows "Office isn't available" with Open Plugin Settings. Re-enable it, and the tab renders again.
8. Replace `plugin.wasm` with one that traps on tick. For example, temporarily add `panic!()` to the `Tick` arm and rebuild. The tab shows "Office stopped: …" with Restart. Revert afterwards.
9. Hello Workspace (API 1) still activates and logs snapshot summaries.
10. Debug frame rate is acceptable (5 fps, and typing isn't blocked). If it stutters, note it in the PR description as the known risk.

- [ ] **Step 3: Docs**

- Write `plugins/pixel-office/README.md`: build and install (`build.sh`, needs `rustup target add wasm32-unknown-unknown`), what each state looks like, and the art rules (palette-only PNGs, sheet layouts point to `src/atlas.rs`).
- Link it from `docs/plugins/getting-started.md`.

- [ ] **Step 4: Commit**

```bash
git add plugins/pixel-office/README.md docs/plugins/getting-started.md
git commit -m "docs(plugins): document installing and reading Pixel Office"
```
