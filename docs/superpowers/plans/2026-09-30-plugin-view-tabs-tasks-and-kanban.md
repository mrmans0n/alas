# Plugin View Tabs, Tasks, Storage and Kanban Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plugin API 3 (declarative native view tabs, `task/start`, per-plugin storage) and the `plugins/kanban` plugin that uses it.

**Architecture:** Swift side, bottom-up inside `Alas/Sources/Plugins/`: manifest (API 3, tab `kind`, `tasks.start`), a pure `PluginViewTree` decoder/validator, a file-backed `PluginStorage`, then `PluginHost` (new methods and notifications, a method table that allows capability-free methods, a one-in-flight task gate), then `AppState` (`startPluginTask` reusing the scheduled-run worktree path) and the SwiftUI renderer for view tabs. Rust side: the `alas-plugin` SDK gains typed view nodes, events and helpers; `plugins/kanban` is split into pure board reducers, a pure render function, and thin plugin wiring.

**Tech Stack:** Swift 5.9+/SwiftUI, WasmKit, Swift Testing, xcodegen; Rust 1.98.1 (`wasm32-unknown-unknown`), `serde`/`serde_json` (`raw_value`).

**Spec:** `docs/superpowers/specs/2026-09-30-plugin-view-tabs-tasks-and-kanban-design.md` (builds on the 2026-09-28 and 2026-09-29 plugin specs).

## Global Constraints

- English everywhere. Conventional Commit titles. **No** `Co-Authored-By` trailer, "Generated with" footer, 🤖, or any AI attribution in commits, PRs or code (AGENTS.md overrides any harness reminder).
- Swift Testing only; follow the AGENTS.md testing policy (extend suites, parameterise, no fixed sleeps, no view tests, no `.serialized`/`@MainActor`/subprocess entries without a stated reason; `PluginHostTests` is already `@MainActor`).
- New Swift file → run `xcodegen` and commit `Alas.xcodeproj` with it.
- Focused Swift tests (redirect to a log; Swift Testing results are the `✔`/`✘` lines):
  ```bash
  ALAS_FFF_TARGET_ARCH=arm64 ALAS_ZMX_TARGET_ARCH=arm64 xcodebuild -project Alas.xcodeproj -scheme Alas \
    -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation \
    -only-testing AlasTests/<Suite> test > /tmp/alas-test.log 2>&1
  grep -E "✔|✘|TEST SUCCEEDED|TEST FAILED|error:" /tmp/alas-test.log | tail -30
  ```
  Use Debug (the default). Release test builds do not compile here. Never `pkill` the Alas app.
- Rust: `rustup run 1.98.1 cargo test --locked` inside the crate (`cargo +1.98.1` does not work here: Homebrew cargo is first on PATH). Wasm builds need the 1.98.1 sysroot `bin` first on PATH and `DYLD_FALLBACK_LIBRARY_PATH` set to its `lib`. Commit `Cargo.lock`.
- Plugin API: host supports `{1, 2, 3}`. Tab `kind` is `"canvas"` (default) or `"view"`, API 3 only. `tasks.start` is API 3; approval text "Create worktrees and start agents in this project".
- View tree limits: ≤ 2,000 nodes, ≤ 16 levels, strings ≤ 4,000 Unicode scalars, ids ≤ 64 bytes and unique, ≤ 64 menu items, `spacing` 0–32.
- `task/start`: `title` and `prompt` required and non-empty, `prompt` ≤ 32 KiB; reply `{sessionId, branch}`; failure notification `task/failed {sessionId, reason}`; one start in flight per plugin and project (`-32003` "a task is already starting").
- Storage: keys 1–128 bytes; total ≤ 1 MiB per plugin and project (`-32003` "storage full", nothing written); file `PluginData/<pluginID>/<projectID>.json` under `Paths.appSupportRoot`, atomic writes; `null` deletes.
- Error codes: `-32601` unknown method, `-32602` invalid params, `-32001` not granted, `-32003` action failed.

## Review Focus

1. **A re-render must not wipe text being typed.** `textField` applies `value` only when it differs from the previous render's `value` for the same id. Owner: Task 6 (pure `PluginTextFieldSync` test).
2. **Deeply nested JSON must not crash Alas.** A 1 MiB message of nested brackets can overflow a recursive decoder; nesting is checked on the raw bytes before decoding. Owner: Task 2, `excessiveNestingIsRejectedBeforeDecoding`.
3. **Any card title must produce a valid branch.** Emoji, slashes, `..`, leading dashes, empty after cleanup. Owner: Task 5, `PluginTaskBranch` parameterised test.
4. **A second Start while one is launching must not create a second worktree,** and the gate must reopen after both success and failure. Owner: Task 4, `taskStartAllowsOneInFlightAndReopens`.
5. **A card whose session has not appeared yet must not drop to Review.** Owner: Task 9, `a_started_card_waits_for_its_session_before_review`.

## Rulings made while planning (spec clarifications)

- **`task/start` and tabs:** the spec says starting a task "does not change the selected worktree or open a tab". The scheduled-run path it reuses creates the worktree with the `.delegated` surface (no selection, no tab) and then opens the agent's chat tab *inside the new worktree*, which is how the session exists at all. That tab is not selected and nothing moves the user's focus. Read the spec line as "does not move the user", which is its intent.
- **No `AppState` integration test for `task/start`.** No test in the repo drives `AppState` worktree creation end to end, and building that harness is large. The decision logic (branch naming) is a pure tested function, the host flow is tested with a fake action, and the wiring is exercised by the live check (Task 11).
- **Add-card form without an Add button.** Events carry only the event's own node `value`, so a button cannot read two text fields. The title field's `submit` stores a draft title; ⌘Return in the prompt field adds the card (using the first prompt line when no title was submitted). After adding, the plugin bumps a form generation number that is part of both field ids, so SwiftUI creates fresh, empty fields.

---

## File Map

**Swift, modify:** `Plugins/PluginManifest.swift` (API 3, `kind`, `tasks.start`), `Plugins/PluginMessages.swift` (payloads), `Plugins/PluginHost.swift` (view trees, events, storage, tasks, method table), `Plugins/PluginManager.swift` (storage per host), `Plugins/AppState+Plugins.swift` (`startTask` action), `Plugins/PluginTabView.swift` (view tabs), `App/AppState+RunSchedules.swift` (extract the free-destination helper).

**Swift, create:** `Plugins/PluginViewTree.swift` (decoder/validator), `Plugins/PluginStorage.swift`, `Plugins/PluginTaskBranch.swift`, `Plugins/PluginViewTabView.swift` (renderer + `PluginTextFieldSync`), `AlasTests/PluginViewTreeTests.swift`, `AlasTests/PluginStorageTests.swift`.

**Swift tests, modify:** `PluginManifestTests`, `PluginHostTests`, `PluginTabTests` (placeholder + text sync).

**Rust:** modify `plugins/alas-plugin/src/lib.rs`; create `plugins/kanban/{Cargo.toml,Cargo.lock,.gitignore,plugin.json,build.sh,README.md,src/lib.rs,src/board.rs,src/view.rs}`.

**Other:** `docs/plugins/api-v3.md`, `docs/plugins/README.md`, `.github/workflows/build.yml`, `scripts/tests/ci-workflow/test-build-workflow.rb`.

---

### Task 1: Manifest API 3, tab kind, `tasks.start`

**Files:** Modify `Alas/Sources/Plugins/PluginManifest.swift`; Test `AlasTests/PluginManifestTests.swift`.

**Interfaces — Produces:** `PluginCapability.tasksStart` (`"tasks.start"`, `minimumAPI` 3); `PluginTabContribution.Kind` (`.canvas`, `.view`) and `PluginTabContribution.kind` (default `.canvas`); `supportedAPIVersions == [1, 2, 3]`.

- [ ] **Step 1: Failing tests.** In `rejectsInvalidManifests` change the unsupported-API case to `"api":4` / `.unsupportedAPI(4)`, and add:

```swift
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","contributes":{"tabs":[{"id":"a","title":"A","kind":"view"}]}}"#, .invalidTab("tab \"a\" sets kind, which requires plugin API 3")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":3,"entry":"p.wasm","contributes":{"tabs":[{"id":"a","title":"A","kind":"table"}]}}"#, .invalidTab("tab \"a\" has unknown kind \"table\"")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","capabilities":["tasks.start"]}"#, .capabilityNeedsNewerAPI("tasks.start", 3)),
```

Update `unsupportedAPIMessageNamesBothVersions` to `.unsupportedAPI(4)` → `"requires plugin API 4; this Alas supports 1, 2, 3"`. Add:

```swift
    @Test func apiThreeTabsDeclareTheirKindAndDefaultToCanvas() throws {
        let manifest = try PluginManifest.parse(Data(#"{"id":"io.x.h","name":"H","version":"1","api":3,"entry":"p.wasm","capabilities":["tasks.start"],"contributes":{"tabs":[{"id":"a","title":"A","kind":"view"},{"id":"b","title":"B"}]}}"#.utf8))
        #expect(manifest.tabs.map(\.kind) == [.view, .canvas])
        #expect(manifest.capabilities == [.tasksStart])
    }
```

- [ ] **Step 2:** Run `-only-testing AlasTests/PluginManifestTests` → compile failure (RED).

- [ ] **Step 3: Implement.**
  - `PluginCapability`: add `case tasksStart = "tasks.start"`; `minimumAPI` → `3`; `summary` → `"Create worktrees and start agents in this project"`. (Move the stray doc comment `/// Plain-language description…` onto `summary`, where it belongs.)
  - `PluginTabContribution`: `enum Kind: String, Sendable { case canvas, view }`, `var kind: Kind = .canvas`. Update its doc comment: "A tab the plugin draws with `alas.present` (canvas) or describes with `view/render` (view)."
  - `supportedAPIVersions = [1, 2, 3]`.
  - `Raw.RawTab`: add `let kind: String?`.
  - `parseTabs(_ raw:, api:)` (pass `api`): after the title check,
    ```swift
            var kind = PluginTabContribution.Kind.canvas
            if let rawKind = entry.kind {
                guard api >= 3 else { throw .invalidTab("tab \"\(id)\" sets kind, which requires plugin API 3") }
                guard let parsed = PluginTabContribution.Kind(rawValue: rawKind) else {
                    throw .invalidTab("tab \"\(id)\" has unknown kind \"\(rawKind)\"")
                }
                kind = parsed
            }
            tabs.append(PluginTabContribution(id: id, title: title, kind: kind))
    ```

- [ ] **Step 4:** GREEN. **Step 5:** Commit `feat(plugins): accept API 3 manifests with view tabs and tasks.start`.

---

### Task 2: `PluginViewTree` decoder and validator

**Files:** Create `Alas/Sources/Plugins/PluginViewTree.swift`, `AlasTests/PluginViewTreeTests.swift`; run `xcodegen`.

**Interfaces — Produces:**

```swift
struct PluginViewNode: Equatable, Sendable {
    enum Kind: String, Sendable { case vstack, hstack, scroll, text, badge, button, textField, menu, card, divider, spacer }
    enum Tone: String, Sendable { case normal, dim, accent, warn, danger }
    struct MenuItem: Equatable, Sendable { let id: String; let label: String }
    let id: String
    let kind: Kind
    var children: [PluginViewNode] = []   // stacks, card; scroll has exactly one
    var text: String? = nil               // text, badge
    var label: String? = nil              // button, menu
    var value: String? = nil              // textField
    var placeholder: String? = nil
    var style: String? = nil              // validated per kind
    var tone: Tone? = nil
    var icon: String? = nil
    var spacing: Int? = nil
    var horizontal = false                // scroll axis
    var multiline = false
    var disabled = false
    var clickable = false
    var items: [MenuItem] = []
}

enum PluginViewTree {
    static let maxNodes = 2_000, maxDepth = 16, maxString = 4_000, maxIDBytes = 64, maxMenuItems = 64
    /// Decodes and validates `root` (the raw JSON of the `root` field). Returns the reason on failure.
    static func decode(_ json: Data) -> Result<PluginViewNode, PluginViewTreeError>
}

struct PluginViewTreeError: Error, Equatable, CustomStringConvertible { let reason: String; var description: String { reason } }
```

Per-kind required fields and allowed `style` values:

| kind | required | allowed `style` |
|---|---|---|
| `vstack`, `hstack` | `children` | – |
| `scroll` | `child`, `axis` ∈ `vertical`, `horizontal` | – |
| `text` | `text` | `body`, `caption`, `title`, `monospaced` |
| `badge` | `text` | – |
| `button` | `label` | `normal`, `primary`, `plain` |
| `textField` | `value` | – |
| `menu` | `label`, `items` | – |
| `card` | `children` | – |
| `divider`, `spacer` | – | – |

- [ ] **Step 1: Failing tests** (`AlasTests/PluginViewTreeTests.swift`):

```swift
import Foundation
import Testing
@testable import Alas

struct PluginViewTreeTests {
    private func decode(_ json: String) -> Result<PluginViewNode, PluginViewTreeError> {
        PluginViewTree.decode(Data(json.utf8))
    }

    @Test func aValidTreeDecodesAndIgnoresUnknownOptionalFields() throws {
        let tree = try decode(#"""
        {"id":"root","kind":"vstack","spacing":8,"future":true,"children":[
          {"id":"t","kind":"text","text":"Hi","style":"title","tone":"dim"},
          {"id":"s","kind":"scroll","axis":"horizontal","child":{"id":"c","kind":"card","clickable":true,"children":[
            {"id":"b","kind":"button","label":"Start","style":"primary","icon":"play"},
            {"id":"f","kind":"textField","value":"","placeholder":"Title","multiline":true},
            {"id":"m","kind":"menu","label":"Move to","items":[{"id":"done","label":"Done"}]}]}}]}
        """#).get()
        #expect(tree.children.count == 2)
        #expect(tree.children[1].horizontal)
        #expect(tree.children[1].children.first?.clickable == true)
        #expect(tree.children[1].children.first?.children[2].items == [.init(id: "done", label: "Done")])
    }

    @Test(arguments: [
        (#"{"id":"a","kind":"vstack","children":[{"id":"a","kind":"divider"}]}"#, "duplicate id \"a\""),
        (#"{"id":"a","kind":"table"}"#, "unknown kind \"table\""),
        (#"{"id":"a","kind":"text"}"#, "text \"a\" needs text"),
        (#"{"id":"a","kind":"button","label":5}"#, "not a valid view tree"),
        (#"{"id":"a","kind":"text","text":"x","style":"huge"}"#, "text \"a\" has unknown style \"huge\""),
        (#"{"id":"a","kind":"vstack","spacing":99,"children":[]}"#, "vstack \"a\" spacing must be 0 to 32"),
        (#"{"id":"a","kind":"scroll","axis":"diagonal","child":{"id":"b","kind":"spacer"}}"#, "scroll \"a\" needs an axis"),
        (#"{"id":"","kind":"spacer"}"#, "node ids must be 1 to 64 bytes"),
    ])
    func invalidTreesAreRejected(json: String, reason: String) {
        #expect(throws: PluginViewTreeError(reason: reason)) { try decode(json).get() }
    }

    @Test(arguments: [(17, "tree is deeper than 16 levels"), (2_001, "tree has more than 2000 nodes")])
    func oversizedTreesAreRejected(size: Int, reason: String) {
        let json = size == 17
            ? (0..<16).reduce(#"{"id":"leaf","kind":"spacer"}"#) { inner, i in #"{"id":"n\#(i)","kind":"card","children":[\#(inner)]}"# }
            : #"{"id":"root","kind":"vstack","children":[\#((0..<2_000).map { #"{"id":"n\#($0)","kind":"spacer"}"# }.joined(separator: ","))]}"#
        #expect(throws: PluginViewTreeError(reason: reason)) { try decode(json).get() }
    }

    /// Review focus 2.
    @Test func excessiveNestingIsRejectedBeforeDecoding() {
        let json = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        #expect(throws: PluginViewTreeError(reason: "tree is deeper than 16 levels")) { try decode(json).get() }
    }

    @Test func overlongStringsAreRejected() {
        let long = String(repeating: "x", count: PluginViewTree.maxString + 1)
        #expect(throws: PluginViewTreeError(reason: "text \"a\" is longer than 4000 characters")) {
            try decode(#"{"id":"a","kind":"text","text":"\#(long)"}"#).get()
        }
    }
}
```

Check the 17-level fixture yourself: 16 `card` wrappers plus the leaf is 17 levels. Adjust the loop bound if your depth counting differs, so the test pins "17 levels rejected" (and add no test that 16 passes unless it's free).

- [ ] **Step 2:** `xcodegen`; run `-only-testing AlasTests/PluginViewTreeTests` → RED.

- [ ] **Step 3: Implement** `PluginViewTree.swift`:
  - `decode` first scans the bytes and tracks the bracket depth of `{`/`[` outside strings (respecting `\"` escapes). Each JSON object level of a node is at most two bracket levels deep (`{` node, `[` children). Reject when the bracket depth exceeds `2 * maxDepth + 2` with the depth reason, *before* calling `JSONDecoder`.
  - Decode into a private `Raw` `Decodable` struct with all fields optional (`child: Raw?` indirect via `Box`, or `children: [Raw]?`). Any type mismatch → `"not a valid view tree"`.
  - Recursive `validate(raw, depth:, ids: inout Set<String>, count: inout Int)` builds `PluginViewNode`, checks: id bytes 1…64 and uniqueness; count ≤ `maxNodes`; depth ≤ `maxDepth` (root depth 1); `kind` known; per-kind required fields (table above) with messages exactly `"<kind> \"<id>\" needs <field>"` (`scroll` without a valid axis: `"scroll \"a\" needs an axis"`); `style` allowed per kind (`"<kind> \"<id>\" has unknown style \"<s>\""`); `tone` known; `spacing` 0…32 (`"<kind> \"<id>\" spacing must be 0 to 32"`); every string field ≤ `maxString` scalars (`"<kind> \"<id>\" is longer than 4000 characters"`); `items` ≤ 64 with non-empty ids unique within the menu.
  - Stop at the first error.

- [ ] **Step 4:** GREEN. **Step 5:** Commit `feat(plugins): decode and validate plugin view trees` (with `Alas.xcodeproj`).

---

### Task 3: `PluginStorage`

**Files:** Create `Alas/Sources/Plugins/PluginStorage.swift`, `AlasTests/PluginStorageTests.swift`; `xcodegen`.

**Interfaces — Produces:**

```swift
/// A plugin's private key-value store for one project, persisted as one JSON file.
@MainActor
final class PluginStorage {
    static let maxKeyBytes = 128
    static let maxTotalBytes = 1 << 20
    enum SetResult: Equatable { case stored, invalidKey, full }
    init(file: URL)
    static func file(pluginID: String, projectID: String, root: URL = Paths.appSupportRoot) -> URL
    func get(_ key: String) -> Data?          // the value's raw JSON, nil when unset
    func set(_ key: String, value: Data?) -> SetResult   // nil deletes; value is raw JSON
    func keys() -> [String]                   // sorted
}
```

- `file(pluginID:projectID:)` = `root/PluginData/<pluginID>/<projectID>.json`. The project id may contain characters unsafe for a filename: percent-encode anything outside `[A-Za-z0-9._-]`.
- Loads lazily on first use; a missing or unreadable file is an empty store.
- The size check sums, over all entries, `key.utf8.count + value.count`. A `set` that would exceed `maxTotalBytes` returns `.full` and changes nothing in memory or on disk.
- Writes with `Data.write(to:options: .atomic)` after creating the parent directory. The file format is a JSON object mapping each key to its value.

- [ ] **Step 1: Failing tests:**

```swift
import Foundation
import Testing
@testable import Alas

@MainActor
struct PluginStorageTests {
    private func makeFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "PluginStorage-\(UUID().uuidString)/io.x.p/proj.json")
    }

    @Test func valuesRoundTripThroughTheFileAndNullDeletes() throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let storage = PluginStorage(file: file)
        #expect(storage.set("board", value: Data(#"{"cards":[1,2]}"#.utf8)) == .stored)
        #expect(storage.set("other", value: Data("3".utf8)) == .stored)
        #expect(storage.set("other", value: nil) == .stored)

        let reopened = PluginStorage(file: file)
        #expect(reopened.keys() == ["board"])
        let value = try #require(reopened.get("board"))
        #expect(try JSONSerialization.jsonObject(with: value) as? [String: [Int]] == ["cards": [1, 2]])
        #expect(reopened.get("other") == nil)
    }

    @Test func aWriteOverTheLimitChangesNothing() throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let storage = PluginStorage(file: file)
        #expect(storage.set("a", value: Data("1".utf8)) == .stored)
        let before = try Data(contentsOf: file)
        let huge = Data(("\"" + String(repeating: "x", count: PluginStorage.maxTotalBytes) + "\"").utf8)
        #expect(storage.set("b", value: huge) == .full)
        #expect(try Data(contentsOf: file) == before)
        #expect(storage.keys() == ["a"])
    }

    @Test(arguments: ["", String(repeating: "k", count: 129)])
    func invalidKeysAreRejected(key: String) {
        #expect(PluginStorage(file: makeFile()).set(key, value: Data("1".utf8)) == .invalidKey)
    }
}
```

- [ ] **Steps 2–5:** RED (`xcodegen` first), implement, GREEN, commit `feat(plugins): add a private key-value store per plugin and project`.

---

### Task 4: Host: view trees, events, storage, `task/start`

**Files:** Modify `Alas/Sources/Plugins/PluginHost.swift`, `PluginMessages.swift`, `PluginManager.swift` (pass storage), `AppState+Plugins.swift` (temporary `startTask` stub), `PluginsWindow.swift` if it builds `PluginHostActions` literally; Test `AlasTests/PluginHostTests.swift` (and fix any `PluginHostActions(...)`/`PluginHost(...)` literals in `PluginManagerDiscoveryTests`, `AgentSidebarRollupTests`).

**Interfaces — Consumes:** Tasks 1–3. **Produces:**

```swift
struct PluginTaskRequest: Equatable, Sendable { let title: String; let prompt: String; let branch: String?; let agent: String? }
enum PluginTaskStart: Equatable { case started(sessionId: String, branch: String); case rejected(code: Int, message: String) }
// PluginHostActions gains:
var startTask: (PluginTaskRequest, @escaping @MainActor (String?) -> Void) -> PluginTaskStart
// `startTask` returns synchronously; the completion is called once, later, with nil on success
// or the failure reason. `.inert` rejects with (-32003, "tasks are not available").
// PluginHost gains:
init(..., storage: PluginStorage, ...)   // after `actions`
private(set) var views: [Int: PluginViewNode]
func viewEvent(tab: Int, id: String, kind: String, value: String?) async
```

Wire payloads (`PluginMessages.swift`):

```swift
struct PluginViewRenderHeader: Decodable { let tab: Int }            // `root` is read raw, see below
struct PluginViewEventParams: Codable, Equatable, Sendable { let tab: Int; let id: String; let kind: String; let value: String? }
struct PluginTaskStartParams: Codable, Sendable { let title: String; let prompt: String; let branch: String?; let agent: String? }
struct PluginTaskStartResult: Codable, Equatable, Sendable { let sessionId: String; let branch: String }
struct PluginTaskFailedParams: Codable, Equatable, Sendable { let sessionId: String; let reason: String }
struct PluginStorageKeyParams: Codable, Sendable { let key: String }
struct PluginStorageKeysResult: Codable, Equatable, Sendable { let keys: [String] }
```

Storage values are arbitrary JSON, so decode `storage/set` params and `view/render`'s `root` with `JSONSerialization` (or a small `RawJSON` wrapper) to get the raw bytes of `params.value` / `params.root`. Don't round-trip them through a typed model.

- [ ] **Step 1: Failing tests** (in `PluginHostTests`). Add a v3 manifest and a helper:

```swift
    static let v3Manifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":3,"entry":"p.wasm","capabilities":["tasks.start"],"contributes":{"tabs":[{"id":"v","title":"V","kind":"view"},{"id":"c","title":"C"}]}}"#
```

  Extend `makeHost` with `storage: PluginStorage = PluginStorage(file: <unique temp file>)` and a `startTask` closure driven by `Recorder` (`var tasks: [PluginTaskRequest] = []`, `var completions: [(String?) -> Void] = []`, returning `.started(sessionId: "s\(tasks.count)", branch: "task/x")`).

  Tests:
  - `aValidRenderReplacesTheTabsTree`: plugin sends `view/render` for tab 0 with a two-node tree → `host.views[0]?.children.count == 1` and host active.
  - `malformedOrMisdirectedViewMessagesStopThePlugin` (parameterised): duplicate id; unknown kind; `view/render` to tab 1 (canvas); `canvas/regions` to tab 0 (view); `tab` 9. Each ends in `.failed` whose reason contains `view/render` or `canvas/regions`. Also presenting a frame to tab 0 via the fixture's `.present(tab: 0, …)` fails with a reason containing "view tab".
  - `viewEventsOnlyReachNodesInTheCurrentTree`: after a render containing a button `go`, `await host.viewEvent(tab: 0, id: "nope", kind: "click", value: nil)` sends nothing and `…id: "go"…` sends one `view/event` (count in `trace`).
  - `taskStartNeedsTheGrant`: without `.tasksStart`, a `task/start` request is answered `-32001` and `recorder.tasks` stays empty.
  - **Review focus 4** `taskStartAllowsOneInFlightAndReopens`: script sends two `task/start` requests in the activation call. The first reply contains `"sessionId":"s1"` and the second `-32003`. Then call `recorder.completions[0](nil)` and deliver a third `task/start` in a later call (use a second script step triggered by `workspaceChanged`); it is answered `"sessionId":"s2"`. Finally complete it with `"boom"` and assert a traced `task/failed` containing `"reason":"boom"`.
  - `invalidTaskParamsAreRejected` (parameterised): empty title, empty prompt, prompt over 32 KiB → `-32602`, nothing started.
  - `storageRoundTripsAndEnforcesItsLimits`: `storage/set {key:"k", value:{"a":1}}` → `{}`, then `storage/get {key:"k"}` reply contains `"value":{"a":1}`, `storage/keys` contains `["k"]`, `storage/set` with an empty key → `-32602`, and one over the limit (a storage whose file already holds ~1 MiB; seed it through the `PluginStorage` API before activation) → `-32003` "storage full". Storage needs no grant (host has `grants: []`).

- [ ] **Step 2:** RED.

- [ ] **Step 3: Implement.**
  - **Method table.** Replace `requiredCapability: [String: PluginCapability]` with `static let methods: [String: PluginCapability?]`, where `nil` means no capability is needed:
    ```swift
    ["workspace/snapshot": .workspaceRead, "worktree/switch": .worktreeSwitch, "session/focus": .sessionFocus,
     "task/start": .tasksStart, "storage/get": nil, "storage/set": nil, "storage/keys": nil]
    ```
    A method missing from the table → `-32601`; with a capability not granted → `-32001`. `storage/*` are API 3 methods: for a manifest with `api < 3` answer `-32601`.
  - **`view/render`** in `handleNotification`: decode `PluginViewRenderHeader`; the tab must exist and be `.view`, else violation `"plugin sent view/render to tab <n>, which is not a view tab"`. Extract the raw `root` bytes, then `PluginViewTree.decode`: on failure a violation `"plugin sent a malformed view/render: <reason>"`, on success `views[tab] = node`.
  - **`canvas/regions`** additionally requires the tab to be `.canvas` (violation text keeps `canvas/regions`).
  - **Frames:** after a delivery, if `delivery.frames` has a key whose tab is `.view`, `fail("plugin presented a frame to view tab <n>")`.
  - **`viewEvent`:** guard `state == .active` and that `views[tab]` contains a node with that `id` (walk the tree); then deliver `view/event` (`PluginViewEventParams`).
  - **`clearCanvas()`** also clears `views`. `isTicking` requires at least one `.canvas` tab.
  - **`task/start`:** decode params (`-32602` on failure); validate non-empty `title`/`prompt` and `prompt.utf8.count <= 32 * 1024` (`-32602`). If `taskInFlight` → `-32003` `"a task is already starting"`. Otherwise set `taskInFlight = true` and call `actions.startTask(request) { [weak self] failure in self?.taskSettled(sessionId:, failure:) }`. `.started` → reply `PluginTaskStartResult`. `.rejected(code, message)` → `taskInFlight = false` and an error reply. `taskSettled` clears `taskInFlight`, and when `failure != nil` and the host is active, delivers `task/failed` in a `Task`. Capture the session id from `.started`: set a local before calling, or have `taskSettled` take it from a stored `pendingTaskSession`.
  - **Storage:** `storage/get` → `{"value": <raw or null>}`; `storage/set` → `.stored` `{}`, `.invalidKey` `-32602 "invalid storage key"`, `.full` `-32003 "storage full"`; `storage/keys` → `PluginStorageKeysResult`. Build the `get` reply by splicing raw JSON (e.g. encode a response with a placeholder and replace it, or assemble the bytes directly). The value must not be re-serialised through a typed model.
  - **`PluginHostActions.startTask`:** add the field and `.inert`. In `AppState+Plugins.swift`, add a temporary `startTask: { _, _ in .rejected(code: -32003, message: "tasks are not available yet") }`; Task 5 replaces it.
  - **`PluginManager.start`:** construct `PluginStorage(file: PluginStorage.file(pluginID: plugin.id, projectID: project.id))` per host.
  - Update the doc comment on `PluginHost` to "(1, 2 or 3)".

- [ ] **Step 4:** GREEN for `PluginHostTests`, `PluginManagerDiscoveryTests`, `PluginRuntimeTests`, `AgentSidebarRollupTests` (the literal updates). **Step 5:** Commit `feat(plugins): view trees, view events, storage and task/start in the host`.

---

### Task 5: `task/start` in `AppState`

**Files:** Create `Alas/Sources/Plugins/PluginTaskBranch.swift`; modify `AppState+Plugins.swift`, `App/AppState+RunSchedules.swift`; Test: add `PluginTaskBranch` tests to `AlasTests/PluginTabTests.swift` (the suite for small pure plugin helpers; rename is not needed).

**Interfaces — Produces:** `enum PluginTaskBranch { static func name(title: String, requested: String?) -> String }` and `AppState.startPluginTask(_:project:completion:) -> PluginTaskStart`.

- [ ] **Step 1: Failing test (Review focus 3):**

```swift
    @Test(arguments: [
        ("Fix login flow", nil as String?, "task/fix-login-flow"),
        ("  Añadir 🚀 soporte / para  X ", nil, "task/anadir-soporte-para-x"),
        ("..--..", nil, "task/task"),
        ("", nil, "task/task"),
        ("x", "feature/my-branch", "feature/my-branch"),
        ("x", "bad..name", "task/bad-name"),
        (String(repeating: "word ", count: 40), nil, "task/" + Array(repeating: "word", count: 40).joined(separator: "-").prefix(48).trimmingCharacters(in: CharacterSet(charactersIn: "-"))),
    ])
    func taskBranchNamesAreAlwaysValid(title: String, requested: String?, expected: String) {
        let name = PluginTaskBranch.name(title: title, requested: requested)
        #expect(name == expected)
        #expect(GitNameValidator.validateBranchName(name) == .valid)
    }
```

(If `GitNameValidator.validateBranchName`'s result isn't `Equatable`, pattern-match `.valid` instead.)

- [ ] **Step 2:** RED.

- [ ] **Step 3: Implement.**
  - `PluginTaskBranch.name`: use `requested` when it is non-empty and valid per `GitNameValidator`. Otherwise slug from `requested ?? title`: fold diacritics (`.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en"))`), lowercase, map every character outside `[a-z0-9]` to `-`, collapse runs of `-`, trim `-`, and cut to 48 characters then re-trim. Empty → `task`. Result `task/<slug>`.
  - In `AppState+RunSchedules.swift`, extract the free-destination part of `createScheduledWorktree` (from `let repoPath` through the `base` computation) into
    ```swift
    func reserveWorktreeDestination(rendered: String, project: ProjectConfig) async
        -> Result<(branch: String, destination: URL, base: String), WorktreeCreationFailure>
    ```
    and call it from `createScheduledWorktree`, with the same messages and behaviour. This is a move, not a rewrite. Run `ScheduledWorktreeDestinationTests` and any `RunSchedule*` suites afterwards.
  - `AppState.startPluginTask(_ request: PluginTaskRequest, project: ProjectConfig, completion: @escaping @MainActor (String?) -> Void) -> PluginTaskStart`:
    1. Resolve the agent: `request.agent ?? defaultAgentID(projectId: project.id, worktreeRoot: URL(fileURLWithPath: project.path))`. Nil → `.rejected(-32003, "no agent is configured for <project>")`. Not an ACP agent (`ACPLaunchCatalog.spec(for:) == nil`) → `.rejected(-32602, "agent <id> cannot take a prompt")`.
    2. `let branch = PluginTaskBranch.name(title:requested:)`, `let sessionID = UUID().uuidString`.
    3. Return `.started(sessionId: sessionID, branch: branch)` immediately. Start a `Task { @MainActor in … }` that calls `reserveWorktreeDestination(rendered: branch, …)` then `createWorktreeAndWait(…, runStartup: true)`, and then `launchWorktreeSurface(.acp(agentId: agent, preparedPrompt: PreparedWorktreeACPPrompt(sessionID: sessionID, promptID: UUID(), text: request.prompt, sendsAutomatically: true, modelID: nil)), worktree:, project:)`. On any failure call `markWorktreeLaunchFailed` when a worktree exists (as `launchScheduledAgent` does), then `completion(message)`; on success `completion(nil)`.
    4. Note: the reply reports the *requested* branch. When the reserved branch gets a numeric suffix, the plugin learns the real branch from the snapshot. Say so in a comment and in `api-v3.md`.
  - `pluginHostActions(for:)`: `startTask: { [weak self] request, completion in self?.startPluginTask(request, project: project, completion: completion) ?? .rejected(code: -32003, message: "Alas is shutting down") }`.

- [ ] **Step 4:** GREEN (`PluginTabTests`, `ScheduledWorktreeDestinationTests`, and the run-schedule suites that exercise `createScheduledWorktree`; find them with `grep -rl "RunSchedule" AlasTests`). **Step 5:** Commit `feat(plugins): start plugin tasks in a new worktree on the scheduled-run path`.

---

### Task 6: View tab rendering

**Files:** Create `Alas/Sources/Plugins/PluginViewTabView.swift`; modify `PluginTabView.swift`; Test `AlasTests/PluginTabTests.swift`; `xcodegen`.

**Interfaces — Produces:** `PluginTabContent.content` replaces `.canvas` (renamed case, same meaning for both kinds); `PluginTabContent.resolve(…, hasContent:)` (renamed from `hasFrame`); `enum PluginTextFieldSync { static func apply(incoming: String, previousIncoming: String?, current: String) -> String }`.

- [ ] **Step 1: Failing tests** (`PluginTabTests`): rename the existing placeholder test's `hasFrame` → `hasContent` and `.canvas` → `.content`; add (Review focus 1):

```swift
    @Test(arguments: [
        ("", nil as String?, "", ""),               // first render
        ("", "", "typing…", "typing…"),             // same value re-rendered: keep typing
        ("draft", "", "typing…", "draft"),          // plugin changed the value: take it
        ("draft", "draft", "draft edited", "draft edited"),
    ])
    func textFieldsOnlyTakeTheValueWhenThePluginChangesIt(incoming: String, previous: String?, current: String, expected: String) {
        #expect(PluginTextFieldSync.apply(incoming: incoming, previousIncoming: previous, current: current) == expected)
    }
```

- [ ] **Step 2:** RED. **Step 3: Implement.**
  - `PluginTextFieldSync.apply`: `previousIncoming == nil || incoming != previousIncoming ? incoming : current`.
  - `PluginTabView`: compute `kind = plugin?.manifest.tabs[tabIndex].kind`; `hasContent` = frame (canvas) or `views[tab]` (view); `.content` → `PluginCanvasView` for canvas, `PluginViewTabView(host:tabIndex:)` for view. The visibility reporter only matters for canvas; keep passing it (ticks already require a canvas tab).
  - `PluginViewTabView` renders `host.views[tabIndex]` recursively with a private `PluginViewNodeView`:
    - **Stacks:** `VStack`/`HStack(alignment: .top, spacing:)`.
    - **Scroll:** `ScrollView(axis)`.
    - **Text:** `Text` with the font from `style` (`body` `.body`, `caption` `.caption`, `title` `.title3.weight(.semibold)`, `monospaced` `.system(.body, design: .monospaced)`) and the colour from `tone`, via the theme: `normal` `fg`, `dim` `fg-dim`, `accent` `accent`, `warn` `warn`, `danger` `danger`. If a theme key doesn't exist, use the closest existing key (check `theme.color` usages).
    - **Badge:** a capsule with caption text.
    - **Button:** `AlasButton` (`style` mapped to its styles) or a plain `Button` for `plain`, with `icon`; `disabled`.
    - **Text field:** a `TextField`, or `TextEditor` + ⌘Return handling when `multiline`. Local `@State` text per node id plus the last incoming value, updated through `PluginTextFieldSync` in `.onChange(of: node.value)`. `submit` sends `viewEvent(… kind: "submit", value: text)`.
    - **Menu:** a `Menu` with a `Button` per item sending `select` with `value: item.id`.
    - **Card:** a rounded, padded background with `tone` border; when `clickable`, wrap it in a `Button`/`.onTapGesture` + `.accessibilityAddTraits(.isButton)` sending `click`.
    - **Divider, spacer:** `Divider`, `Spacer`.
    - Everything is keyed by `node.id` (`ForEach(node.children, id: \.id)`), so SwiftUI keeps identity and focus.
  - Keep `PluginViewTabView` simple and readable; it is not unit-tested (policy). Put the text-sync logic in `PluginTextFieldSync` only.

- [ ] **Step 4:** `xcodegen`; GREEN for `PluginTabTests`; the app target compiles. **Step 5:** Commit `feat(plugins): render plugin view tabs with native controls`.

---

### Task 7: API 3 docs

**Files:** Create `docs/plugins/api-v3.md`; modify `docs/plugins/README.md` (link it).

- [ ] Write `api-v3.md` from spec sections 1 and 2 plus this plan's Global Constraints: versioning; tab `kind`; `view/render` with the node table, rules (theme styling, `textField` value semantics, unknown optional fields ignored); `view/event`; limits and what stops the plugin; `task/start` (params, reply, the branch note from Task 5, `task/failed`, rate limit, errors); storage (methods, limits, file location, lifetime). Link from `README.md`.
- [ ] Commit `docs(plugins): document plugin API 3`.

---

### Task 8: SDK: view nodes, events, tasks, storage

**Files:** Modify `plugins/alas-plugin/src/lib.rs`.

**Interfaces — Produces (Rust):**

```rust
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Node {
    Vstack { id: String, children: Vec<Node>, #[serde(skip_serializing_if = "Option::is_none")] spacing: Option<u8> },
    Hstack { id: String, children: Vec<Node>, #[serde(skip_serializing_if = "Option::is_none")] spacing: Option<u8> },
    Scroll { id: String, axis: Axis, child: Box<Node> },
    Text { id: String, text: String, #[serde(skip_serializing_if = "Option::is_none")] style: Option<TextStyle>, #[serde(skip_serializing_if = "Option::is_none")] tone: Option<Tone> },
    Badge { id: String, text: String, #[serde(skip_serializing_if = "Option::is_none")] tone: Option<Tone> },
    Button { id: String, label: String, #[serde(skip_serializing_if = "Option::is_none")] icon: Option<String>, #[serde(skip_serializing_if = "Option::is_none")] style: Option<ButtonStyle>, #[serde(skip_serializing_if = "std::ops::Not::not")] disabled: bool },
    TextField { id: String, value: String, #[serde(skip_serializing_if = "Option::is_none")] placeholder: Option<String>, #[serde(skip_serializing_if = "std::ops::Not::not")] multiline: bool },
    Menu { id: String, label: String, items: Vec<MenuItem> },
    Card { id: String, children: Vec<Node>, #[serde(skip_serializing_if = "Option::is_none")] tone: Option<Tone>, #[serde(skip_serializing_if = "std::ops::Not::not")] clickable: bool },
    Divider { id: String },
    Spacer { id: String },
}
// Axis { Vertical, Horizontal }, TextStyle { Body, Caption, Title, Monospaced }, Tone { Normal, Dim, Accent, Warn, Danger },
// ButtonStyle { Normal, Primary, Plain } — all Serialize, rename_all = "camelCase" (lowercase on the wire).
#[derive(Debug, Clone, PartialEq, Serialize)] pub struct MenuItem { pub id: String, pub label: String }

pub fn render(tab: u32, root: &Node);                      // sends view/render
pub fn task_start(title: &str, prompt: &str) -> i64;       // request id; reply is Event::Reply with {sessionId, branch}
pub fn storage_get(key: &str) -> i64;                      // reply value at result["value"]
pub fn storage_set(key: &str, value: &Value) -> i64;
// Event gains:
ViewEvent { tab: u32, id: String, kind: String, value: Option<String> },
TaskFailed { session_id: String, reason: String },
```

Check the wire names against Task 2: `textField` must serialise as `"kind":"textField"` (camelCase), not `text_field`.

- [ ] **Step 1: Failing tests:** `view_nodes_encode_to_the_wire_shape` (a small tree including `TextField`, `Menu`, `Card` compares with `json!` output, including omission of default fields); `view_events_and_task_failures_decode`; `task_and_storage_helpers_send_the_documented_requests` (method names and params via `test_host::take_sent`).
- [ ] **Steps 2–4:** RED, implement (`dispatch` gains `view/event` → `ViewEvent`, `task/failed` → `TaskFailed`, typed params like the others), GREEN with `--locked`. `hello-workspace` must still build.
- [ ] **Step 5:** Commit `feat(plugins): SDK support for view tabs, tasks and storage`.

---

### Task 9: Kanban board model

**Files:** Create `plugins/kanban/{Cargo.toml,.gitignore,plugin.json,src/lib.rs,src/board.rs}` (`lib.rs` only declares `pub mod board;` for now).

`Cargo.toml` mirrors `pixel-office` without `png` or `[build-dependencies]`: `crate-type = ["cdylib", "rlib"]`, depending on `alas-plugin = { path = "../alas-plugin" }`, `serde = { version = "1", features = ["derive"] }` and `serde_json = "1"`, plus the same release profile. `plugin.json`: id `io.nlopez.kanban`, name `Kanban`, version `0.1.0`, `api: 3`, entry `plugin.wasm`, capabilities `["workspace.read", "session.focus", "tasks.start"]`, one tab `{"id":"board","title":"Board","kind":"view"}`.

**Interfaces — Produces (`board.rs`, pure, no SDK calls):**

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Column { Backlog, Running, NeedsYou, Review, Done }
impl Column { pub const ALL: [Column; 5]; pub fn title(self) -> &'static str; pub fn key(self) -> &'static str; pub fn from_key(&str) -> Option<Column> }

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Card { pub id: u64, pub title: String, pub prompt: String, pub column: Column,
    pub session_id: Option<String>, pub branch: Option<String>, pub error: Option<String>,
    pub following: bool, pub seen: bool, pub agent_state: Option<String> }

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Board { pub cards: Vec<Card>, pub next_id: u64 }

impl Board {
    pub fn add(&mut self, title: &str, prompt: &str) -> u64;         // trims; empty title → first prompt line; ignores both empty
    pub fn delete(&mut self, id: u64);
    pub fn started(&mut self, id: u64, session_id: String, branch: String); // Running, following, !seen, error cleared
    pub fn start_failed(&mut self, id: u64, reason: &str);           // Backlog, error set, session cleared
    pub fn task_failed(&mut self, session_id: &str, reason: &str);   // finds by session → start_failed
    pub fn move_to(&mut self, id: u64, column: Column);              // Done/Backlog → following=false; others → following=true if it has a session
    pub fn sync(&mut self, sessions: &[(String, String)]);           // (session id, state) from the snapshot
    pub fn in_column(&self, column: Column) -> Vec<&Card>;           // insertion order
}
```

`sync` rules (spec table): for each card with `following && session_id`:
- **Session present:** `seen = true`, set `agent_state`. Then `running` → Running; `awaiting_input`/`permission_request` → NeedsYou; `idle` → Review; `unknown` → unchanged.
- **Session absent:** move to Review only if `seen`, otherwise unchanged.

- [ ] **Step 1: Failing tests** in `board.rs` (`#[cfg(test)]`):
  - `session_states_move_following_cards` (table-driven over the four states);
  - **Review focus 5** `a_started_card_waits_for_its_session_before_review` (absent before seen → still Running; seen then absent → Review);
  - `done_and_backlog_stop_following` (move to Done, then a running state keeps it in Done; move to Review keeps following);
  - `a_failed_start_returns_to_backlog_with_the_reason` (both `start_failed` and `task_failed`);
  - `adding_uses_the_first_prompt_line_without_a_title_and_ignores_empty_cards`;
  - `the_board_round_trips_through_json`.
- [ ] **Steps 2–4:** RED, implement, GREEN (`rustup run 1.98.1 cargo test`; then `--locked` once `Cargo.lock` exists).
- [ ] **Step 5:** Commit `feat(kanban): board model and card movement`.

---

### Task 10: Kanban view and plugin wiring

**Files:** Create `plugins/kanban/src/view.rs`, `build.sh` (copy of `pixel-office/build.sh`), `README.md`; modify `src/lib.rs`, `.github/workflows/build.yml` (matrix entry `plugins/kanban` / `1.98.1` and `plugins/kanban/Cargo.lock` in `hashFiles`), `scripts/tests/ci-workflow/test-build-workflow.rb` (add `["plugins/kanban", "1.98.1"]` after `plugins/alas-plugin`, matching the workflow order).

**Interfaces — Produces:** `view::render(board: &Board, form: u64) -> Node` and the `Kanban` plugin.

`view.rs`: a root `vstack` → `scroll` (horizontal) → `hstack` of five column `vstack`s (`id` `col-<key>`). Each column has a header `hstack` with a title `text` (style `title`) and a count `badge`, then its cards. Backlog starts with the form: `textField` `new-title-<form>` (placeholder "Title") and multiline `textField` `new-prompt-<form>` (placeholder "Prompt — ⌘Return to add"). A card is a `card` `card-<id>`, clickable when it has a session. Inside it:
- a `text` title;
- a dim caption `text` with the prompt preview (first 120 characters);
- a monospaced `text` with the branch, when set;
- a `badge` with the agent state (tone `warn` for needs-you states, `accent` for running);
- a `danger` `text` with `Start failed: <error>`, when set;
- a buttons `hstack`: Backlog cards get `button` `start-<id>` "Start" (primary, icon `play.fill`) and `button` `delete-<id>` "Delete" (plain); every card gets `menu` `move-<id>` "Move to" with items keyed by `Column::key` for the other four columns.

`lib.rs` (`Kanban` implements `Plugin`, `export_plugin!(Kanban)`), with state `board`, `form: u64`, `draft_title`, `pending: Vec<(i64, u64)>` (task request id → card id), `loaded: bool`, `load_request: i64`:
- **Activate:** `load_request = storage_get("board")` and `request_snapshot()`.
- **Loading:** a `Reply` for `load_request` → parse `result["value"]` into `Board` (missing or invalid → default), `loaded = true`, render.
- **Snapshot events:** `Snapshot`/`WorkspaceChanged` → collect `(session.id, session.state)` from every worktree, `board.sync`, save, render.
- **`ViewEvent` by id prefix:**
  - `new-title-*` submit → `draft_title = value`.
  - `new-prompt-*` submit → `board.add(draft_title, value)`, clear `draft_title`, `form += 1`.
  - `start-<id>` click → `pending.push((task_start(title, prompt), id))`.
  - `delete-<id>` → delete.
  - `move-<id>` select → `move_to` with `Column::from_key(value)`.
  - `card-<id>` click with a session → `request("session/focus", {"id": session})`.
  - Every change saves (`storage_set("board", board)`) and re-renders.
- **Task replies:** a `Reply` for a pending task id → `Ok` gives `started(card, result["sessionId"], result["branch"])`; `Err` gives `start_failed(card, message)`. Remove the entry from `pending`, save and render.
- **`TaskFailed`:** `board.task_failed`, save, render.
- **Other replies:** `Err` replies not matched above → `log("warn", …)`.
- **Before loading:** render nothing until `loaded`, so the tab shows the loading spinner.

- [ ] **Step 1: Failing tests** in `view.rs`: `the_board_renders_five_columns_with_counts`; `backlog_cards_have_start_and_delete_and_started_cards_are_clickable`; `form_field_ids_change_with_the_form_generation`. In `lib.rs`, via `test_host`: `starting_a_card_requests_a_task_and_a_reply_moves_it_to_running` (feed a `ViewEvent` for `start-0`, find the `task/start` request id in `take_sent`, feed a reply `{sessionId:"s", branch:"task/x"}`, and check the last `view/render` has `card-0` in `col-running`) and `a_failed_start_shows_the_reason_in_backlog`.
- [ ] **Steps 2–4:** RED, implement, GREEN with `--locked`. Build the release wasm and check the import list: the module imports only `alas.send` (no `present`, since a view plugin never draws).
- [ ] Write a short `README.md`: build and install (`plugins/kanban/build.sh`, optional `ALAS_APP_SUPPORT_DIR`), approve, open **View → Plugins → Board**, the columns and how cards move, and a note that each Start creates a worktree.
- [ ] Run `bash scripts/tests/ci-workflow/run.sh` → `ok`.
- [ ] **Step 5:** Commit `feat(kanban): Kanban board plugin that starts and follows agents`.

---

### Task 11: Fuel check and live check

- [ ] **Fuel (throwaway, never committed).** Use the probe approach from #1647: a temporary `AlasTests/ZZFuelProbeTests.swift` that loads the built kanban wasm into a real `PluginHost` (Debug config), with storage pre-seeded with a 200-card board (build the JSON with the Rust `Board` serialisation, e.g. a tiny test in the kanban crate that prints it to `/tmp`) and a snapshot mentioning those sessions. Bisect the minimum `fuelPerCall` for activation plus the storage reply plus the first render. **Target: under 12.5M.** If it misses, report the number and profile the render; do not change host limits. Delete the probe and `git checkout -- Alas.xcodeproj` afterwards.
- [ ] **Live check** (isolated profile, following the saved recipe in project memory `alas-drive-second-instance-via-osascript`):
  - build the app from this branch and launch it with `ALAS_APP_SUPPORT_DIR=/tmp/alas-kanban-e2e`;
  - install with `ALAS_APP_SUPPORT_DIR=/tmp/alas-kanban-e2e plugins/kanban/build.sh`;
  - enable Plugins, approve Kanban, open **View → Plugins → Board**;
  - add a card whose prompt is harmless and read-only (e.g. "Reply with only the word hello"), then Start;
  - confirm a new worktree appears without the selection moving, and the card goes Running → Review;
  - click the card to open its session;
  - quit and relaunch, and see the board restored.

  Screenshot each step. Afterwards, delete the created worktree and branch, `/tmp/alas-kanban-e2e`, and the profile's preferences suite. The profile's approvals live in the isolated suite now, so nothing touches the everyday preferences.
