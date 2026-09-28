# Plugin Contract v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an independently built Wasm plugin load into Alas through a documented, versioned contract (manifest, trust, lifecycle, JSON-RPC protocol, and capability enforcement), and prove it with a Rust sample plugin.

**Architecture:** There are five layers, each in its own file under `Alas/Sources/Plugins/`:
- `PluginManifest` is pure validation.
- `PluginTrust` holds hash-pinned approvals.
- `PluginRuntime` wraps one WasmKit instance on a serial queue with limits, and moves only bytes.
- `PluginHost` is the main-actor JSON-RPC state machine for one plugin in one project.
- `PluginManager` handles discovery and host lifecycle, and is driven from a Debug-only window.

The host never re-enters the plugin: messages sent during `alas_handle` are queued and processed after the call returns.

**Tech Stack:** Swift 6, SwiftUI/AppKit, WasmKit (pinned revision `1e9c513df0f246e7d9647665430e1f01f50fead2`, already in `project.yml`), the WAT package product for test fixtures, Swift Testing, and Rust (`wasm32-unknown-unknown`, `serde_json`) for the sample.

**Spec:** `docs/superpowers/specs/2026-09-28-plugin-contract-v1-design.md`

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Tests use Swift Testing (`import Testing`), not XCTest. `@testable import Alas`.
- After adding or removing any file under `Alas/` or `AlasTests/`, run `xcodegen` before building, or the file silently won't compile or run.
- Commit titles use Conventional Commits, for example `feat(plugins): …` or `test(plugins): …`. Add no `Co-Authored-By` trailers or any other agent attribution.
- Import WasmKit as `@_spi(Fuzzing) import WasmKit` wherever `Store.resourceLimiter` is used.
- Plugin API version supported by this host: exactly `1`.
- v1 capabilities: `workspace.read`, `worktree.switch`. No others.
- Limits: fuel `25_000_000` per `alas_handle`, memory `64 MiB`, message `1 MiB` in either direction, `64` `alas.send` calls per `alas_handle`.
- Error codes: `-32601` unknown method, `-32602` invalid params, `-32001` capability not granted, `-32003` action failed.
- Plugins folder: `~/Library/Application Support/Alas/Plugins/<folder>/{plugin.json, <entry>}`.
- Use this local test command. Run it from the repo root, and never pipe `xcodebuild` output (the pipe hides its exit code):

  ```bash
  export ALAS_FFF_TARGET_ARCH=arm64 ALAS_ZMX_TARGET_ARCH=arm64 ALAS_ZMX_OPTIONAL=1
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' \
    ONLY_ACTIVE_ARCH=YES ARCHS=arm64 -only-testing AlasTests/<Suite> test > /tmp/alas-test.log 2>&1; echo EXIT=$?
  grep -E "✔|✘|\*\* TEST" /tmp/alas-test.log
  ```

  Swift Testing results are the `✔`/`✘` lines. Ignore the XCTest bridge's "Executed 0 tests" line.

## Deviations From the Spec

These are deliberate. The spec is updated in the same commit as this plan.

1. **Approval UI:** approval is an inline "Approve and run" button in the Debug → Plugins window, not a `RepoHookApprovalSheet`-style sheet. The repo-hook sheet depends on a presenter queue that's overkill for a Debug-only surface. The Phase 3 install UI owns the real sheet.
2. **Where `PluginManager` lives:** it's owned by the Debug window controller and starts the first time Debug → Plugins… opens, not on `AppState`. This keeps plugin discovery out of the many tests that construct `AppState`. Phase 3 moves it onto `AppState`.
3. **`worktree/switch`:** it calls `AppState.focusGlobalWorktree(id:projectId:)` after checking that the id belongs to the project. `AlasActionService.switch` resolves user-typed branch names and paths, not ids.
4. **No pending-request cap or `-32002`:** every v1 host method answers immediately, so no request is ever pending across calls, and the 64-send cap already bounds each call. Add the cap with the first async host method, such as network.
5. **Initial `workspace/changed`:** it's delivered by the 500 ms snapshot poll, which also rate-limits later changes, rather than as a separate send right after activation.
6. **Snapshot sessions:** the snapshot lists `AgentSidebarRollup.active` rows only, which excludes `detached` history. `detached` stays in the state-name mapping for completeness.

## Review Focus

- **A plugin whose `alas_alloc` returns a pointer outside its memory,** for example a leaky allocator that hits the cap. Expected: `badGuestRange`, and the plugin is marked failed. Alas must not crash. The pinning test is in Task 3.
- **Stray responses,** such as a second `alas/activate` response or a response to an id Alas never sent. Expected: ignored, and the plugin stays `active`. The pinning test is in Task 5.
- **Plugin folders that are half-installed or conflict:** a missing wasm file, or two folders with the same `id`. Expected: listed as invalid with a reason, and neither conflicting plugin runs. The pinning test is in Task 6.
- **Plugins that import WASI or anything besides `alas.send`.** Expected: loading fails with an instantiation error. The Rust sample must not accidentally need WASI. The pinning test is in Task 3.
- **Deactivation while a call is still running** (the project closes during a long call). Expected: whatever the plugin sent during that call is dropped. The pinning test is in Task 5.

---

### Task 1: Manifest

**Files:**
- Create: `Alas/Sources/Plugins/PluginManifest.swift`
- Test: `AlasTests/PluginManifestTests.swift`

**Interfaces:**
- Produces:
  - `enum PluginCapability: String, Codable, CaseIterable, Sendable, Hashable` with cases `workspaceRead = "workspace.read"` and `worktreeSwitch = "worktree.switch"`, plus `var summary: String`.
  - `struct PluginManifest: Equatable, Sendable` with `id, name, version, entry: String`, `api: Int`, and `capabilities: [PluginCapability]`; `static let supportedAPIVersions: [Int]`; and `static func parse(_ data: Data) throws(PluginManifestError) -> PluginManifest`.
  - `enum PluginManifestError: Error, Equatable, CustomStringConvertible` with cases `malformed`, `missingField(String)`, `invalidID(String)`, `unsupportedAPI(Int)`, `unknownCapability(String)`, `invalidEntry(String)`.

- [ ] **Step 1: Write the failing tests**

`AlasTests/PluginManifestTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

struct PluginManifestTests {
    @Test func parsesAValidManifestIgnoringUnknownFields() throws {
        let json = #"{"id":"io.nlopez.hello","name":"Hello","version":"0.1.0","api":1,"entry":"plugin.wasm","capabilities":["workspace.read"],"future":{"x":1}}"#
        let manifest = try PluginManifest.parse(Data(json.utf8))
        #expect(manifest == PluginManifest(
            id: "io.nlopez.hello", name: "Hello", version: "0.1.0", api: 1,
            entry: "plugin.wasm", capabilities: [.workspaceRead]))
    }

    @Test(arguments: [
        ("{", PluginManifestError.malformed),
        (#"{"name":"H","version":"1","api":1,"entry":"p.wasm"}"#, .missingField("id")),
        (#"{"id":"io.x.h","name":" ","version":"1","api":1,"entry":"p.wasm"}"#, .missingField("name")),
        (#"{"id":"Hello","name":"H","version":"1","api":1,"entry":"p.wasm"}"#, .invalidID("Hello")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm"}"#, .unsupportedAPI(2)),
        (#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"p.wasm","capabilities":["network"]}"#, .unknownCapability("network")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"../p.wasm"}"#, .invalidEntry("../p.wasm")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"/tmp/p.wasm"}"#, .invalidEntry("/tmp/p.wasm")),
    ])
    func rejectsInvalidManifests(json: String, expected: PluginManifestError) {
        #expect(throws: expected) { try PluginManifest.parse(Data(json.utf8)) }
    }

    @Test func unsupportedAPIMessageNamesBothVersions() {
        #expect(PluginManifestError.unsupportedAPI(2).description == "requires plugin API 2; this Alas supports 1")
    }
}
```

- [ ] **Step 2: Create an empty source file, regenerate the project, and confirm the tests fail**

Create `Alas/Sources/Plugins/PluginManifest.swift` containing only `import Foundation`. Then run `xcodegen`, followed by the test command with `<Suite>` = `PluginManifestTests`.
Expected: the build fails with `cannot find 'PluginManifest' in scope`.

- [ ] **Step 3: Implement**

`Alas/Sources/Plugins/PluginManifest.swift`:

```swift
import Foundation

enum PluginCapability: String, Codable, CaseIterable, Sendable, Hashable {
    case workspaceRead = "workspace.read"
    case worktreeSwitch = "worktree.switch"

    /// Plain-language description shown when the user approves a plugin.
    var summary: String {
        switch self {
        case .workspaceRead: "Read this project's worktrees and what their agent sessions are doing"
        case .worktreeSwitch: "Switch the selected worktree"
        }
    }
}

enum PluginManifestError: Error, Equatable, CustomStringConvertible {
    case malformed
    case missingField(String)
    case invalidID(String)
    case unsupportedAPI(Int)
    case unknownCapability(String)
    case invalidEntry(String)

    var description: String {
        switch self {
        case .malformed:
            "plugin.json is not a valid JSON object"
        case .missingField(let field):
            "plugin.json is missing \"\(field)\""
        case .invalidID(let id):
            "invalid plugin id \"\(id)\"; use reverse-DNS such as io.example.plugin"
        case .unsupportedAPI(let api):
            "requires plugin API \(api); this Alas supports \(PluginManifest.supportedAPIVersions.map(String.init).joined(separator: ", "))"
        case .unknownCapability(let name):
            "unknown capability \"\(name)\""
        case .invalidEntry(let entry):
            "entry \"\(entry)\" must be a relative path inside the plugin folder"
        }
    }
}

/// `plugin.json`. Unknown fields are ignored so newer manifests still load.
struct PluginManifest: Equatable, Sendable {
    static let supportedAPIVersions = [1]

    let id: String
    let name: String
    let version: String
    let api: Int
    let entry: String
    let capabilities: [PluginCapability]

    static func parse(_ data: Data) throws(PluginManifestError) -> PluginManifest {
        struct Raw: Decodable {
            let id: String?
            let name: String?
            let version: String?
            let api: Int?
            let entry: String?
            let capabilities: [String]?
        }
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            throw .malformed
        }

        func required(_ value: String?, _ field: String) throws(PluginManifestError) -> String {
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw .missingField(field)
            }
            return value
        }
        let id = try required(raw.id, "id")
        let name = try required(raw.name, "name")
        let version = try required(raw.version, "version")
        guard let api = raw.api else { throw .missingField("api") }
        let entry = try required(raw.entry, "entry")

        guard id.wholeMatch(of: /[a-z0-9-]+(\.[a-z0-9-]+)+/) != nil else { throw .invalidID(id) }
        guard supportedAPIVersions.contains(api) else { throw .unsupportedAPI(api) }
        var capabilities: [PluginCapability] = []
        for name in raw.capabilities ?? [] {
            guard let capability = PluginCapability(rawValue: name) else { throw .unknownCapability(name) }
            capabilities.append(capability)
        }
        guard !entry.hasPrefix("/"), !entry.split(separator: "/").contains("..") else {
            throw .invalidEntry(entry)
        }
        return PluginManifest(
            id: id, name: name, version: version, api: api, entry: entry, capabilities: capabilities)
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run the test command with `<Suite>` = `PluginManifestTests`.
Expected: `✔` for all three tests (the parameterized one covers 8 cases), and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Plugins/PluginManifest.swift AlasTests/PluginManifestTests.swift Alas.xcodeproj
git commit -m "feat(plugins): parse and validate plugin manifests"
```

---

### Task 2: Trust and approvals

**Files:**
- Create: `Alas/Sources/Plugins/PluginTrust.swift`
- Test: `AlasTests/PluginTrustTests.swift`

**Interfaces:**
- Consumes: `PluginCapability` (Task 1).
- Produces:
  - `enum PluginTrust { static func hash(manifest: Data, wasm: Data) -> String }`
  - `struct PluginApproval: Codable, Equatable, Sendable { let id: String; let hash: String; let capabilities: [PluginCapability] }`
  - `struct PluginApprovalStore` with `init(defaults: UserDefaults = .standard)`, `func approval(id: String, hash: String) -> PluginApproval?`, `func approve(_ approval: PluginApproval)`, and `func revoke(id: String)`.

- [ ] **Step 1: Write the failing test**

`AlasTests/PluginTrustTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

struct PluginTrustTests {
    @Test func changingTheWasmRequiresApprovalAgain() throws {
        let suite = "PluginTrustTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PluginApprovalStore(defaults: defaults)
        let manifest = Data("{}".utf8)
        let approved = PluginTrust.hash(manifest: manifest, wasm: Data([0, 1]))
        store.approve(PluginApproval(id: "io.x.p", hash: approved, capabilities: [.workspaceRead]))

        #expect(store.approval(id: "io.x.p", hash: approved)?.capabilities == [.workspaceRead])
        #expect(store.approval(id: "io.x.p", hash: PluginTrust.hash(manifest: manifest, wasm: Data([0, 2]))) == nil)
    }
}
```

- [ ] **Step 2: Create an empty source file, regenerate, and confirm the test fails**

Create `Alas/Sources/Plugins/PluginTrust.swift` containing only `import Foundation`. Run `xcodegen`, then the test command with `<Suite>` = `PluginTrustTests`.
Expected: the build fails with `cannot find 'PluginApprovalStore' in scope`.

- [ ] **Step 3: Implement**

`Alas/Sources/Plugins/PluginTrust.swift`:

```swift
import CryptoKit
import Foundation

/// Approval key for a plugin. Mirrors `RepoHookTrust`: any byte change to the
/// manifest or the wasm yields a new hash, so the user must approve again.
enum PluginTrust {
    private static let version = "alas-plugin-trust-v1"

    static func hash(manifest: Data, wasm: Data) -> String {
        var payload = Data("\(version)\u{0}".utf8)
        payload.append(manifest)
        payload.append(0)
        payload.append(wasm)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }
}

/// `capabilities` is what the user granted, stored separately from the
/// manifest's request so later versions can grant a subset.
struct PluginApproval: Codable, Equatable, Sendable {
    let id: String
    let hash: String
    let capabilities: [PluginCapability]
}

struct PluginApprovalStore {
    private static let key = "pluginApprovals.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func approval(id: String, hash: String) -> PluginApproval? {
        guard let approval = all()[id], approval.hash == hash else { return nil }
        return approval
    }

    func approve(_ approval: PluginApproval) {
        var approvals = all()
        approvals[approval.id] = approval
        save(approvals)
    }

    func revoke(id: String) {
        var approvals = all()
        approvals[id] = nil
        save(approvals)
    }

    private func all() -> [String: PluginApproval] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: PluginApproval].self, from: data)) ?? [:]
    }

    private func save(_ approvals: [String: PluginApproval]) {
        defaults.set(try? JSONEncoder().encode(approvals), forKey: Self.key)
    }
}
```

- [ ] **Step 4: Run the test and confirm it passes**

Run the test command with `<Suite>` = `PluginTrustTests`. Expected: `✔ changingTheWasmRequiresApprovalAgain()`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Plugins/PluginTrust.swift AlasTests/PluginTrustTests.swift Alas.xcodeproj
git commit -m "feat(plugins): pin plugin approvals to manifest and wasm hash"
```

---

### Task 3: Runtime

**Files:**
- Create: `Alas/Sources/Plugins/PluginRuntime.swift`
- Create: `Alas/Sources/Plugins/PluginWAT.swift` (Debug-only wrapper around `wat2wasm`, so tests don't import the WAT module directly)
- Create: `AlasTests/PluginWATFixture.swift` (scripted test plugin builder, shared with Task 5)
- Test: `AlasTests/PluginRuntimeTests.swift`

**Interfaces:**
- Produces:
  - `struct PluginLimits: Sendable, Equatable` with `var fuelPerCall: UInt64 = 25_000_000`, `var maxMemoryBytes = 64 << 20`, `var maxMessageBytes = 1 << 20`, and `var maxSendsPerCall = 64`.
  - `enum PluginRuntimeError: Error, Equatable, CustomStringConvertible` with cases `instantiation(String)`, `missingExport(String)`, `badGuestRange(ptr: UInt32, len: UInt32)`, `messageTooLarge(Int)`, `tooManySends(Int)`, `trap(String)`.
  - `final class PluginRuntime: @unchecked Sendable` with `static func load(wasm: [UInt8], limits: PluginLimits) async throws -> PluginRuntime` and `func handle(_ message: Data) async throws -> [Data]`, which returns the messages the plugin sent during the call.
  - `enum PluginWAT { static func compile(_ text: String) throws -> [UInt8] }`, `#if DEBUG` only.
  - In tests: `enum PluginFixtureStep: Sendable` with cases `send(String)`, `sendRepeated(String, times: Int)`, `sendRange(ptr: Int, len: Int)`, `trap`, `spin`; and `enum PluginWATFixture { static func wasm(_ script: [[PluginFixtureStep]], extraImports: String = "", allocReturns: Int? = nil) throws -> [UInt8] }`. Call N of `alas_handle` runs `script[N]`, and calls past the end do nothing.

- [ ] **Step 1: Write the fixture builder and failing tests**

`AlasTests/PluginWATFixture.swift`:

```swift
import Foundation
@testable import Alas

enum PluginFixtureStep: Sendable {
    case send(String)
    case sendRepeated(String, times: Int)
    case sendRange(ptr: Int, len: Int)
    case trap
    case spin
}

/// Builds a plugin whose Nth `alas_handle` call runs `script[N]`. Calls past the
/// end of the script do nothing. Message text is stored in data segments from
/// offset 1024; `alas_alloc` bumps from 32768 unless `allocReturns` pins it.
enum PluginWATFixture {
    static func wasm(
        _ script: [[PluginFixtureStep]],
        extraImports: String = "",
        allocReturns: Int? = nil
    ) throws -> [UInt8] {
        var data = ""
        var offset = 1024
        var calls = ""
        for (index, steps) in script.enumerated() {
            var body = ""
            for step in steps {
                switch step {
                case .send(let text), .sendRepeated(let text, _):
                    let length = text.utf8.count
                    data += "(data (i32.const \(offset)) \"\(escape(text))\")\n"
                    let call = "(call $send (i32.const \(offset)) (i32.const \(length)))"
                    if case .sendRepeated(_, let times) = step {
                        body += String(repeating: call, count: times)
                    } else {
                        body += call
                    }
                    offset += length
                case .sendRange(let ptr, let len):
                    body += "(call $send (i32.const \(ptr)) (i32.const \(len)))"
                case .trap:
                    body += "unreachable"
                case .spin:
                    body += "(loop $forever (br $forever))"
                }
            }
            calls += "(if (i32.eq (global.get $calls) (i32.const \(index))) (then \(body)))\n"
        }
        let alloc = allocReturns.map { "(i32.const \($0))" } ?? """
            (local.set $p (global.get $heap))
            (global.set $heap (i32.add (global.get $heap) (local.get $n)))
            (local.get $p)
            """
        return try PluginWAT.compile("""
        (module
          (import "alas" "send" (func $send (param i32 i32)))
          \(extraImports)
          (memory (export "memory") 1)
          (global $heap (mut i32) (i32.const 32768))
          (global $calls (mut i32) (i32.const 0))
          \(data)
          (func (export "alas_alloc") (param $n i32) (result i32)
            (local $p i32)
            \(alloc))
          (func (export "alas_handle") (param $ptr i32) (param $len i32)
            \(calls)
            (global.set $calls (i32.add (global.get $calls) (i32.const 1))))
        )
        """)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
```

`AlasTests/PluginRuntimeTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

struct PluginRuntimeTests {
    static let limits = PluginLimits(
        fuelPerCall: 1_000_000, maxMemoryBytes: 1 << 20, maxMessageBytes: 1024, maxSendsPerCall: 4)

    @Test func returnsMessagesSentDuringTheCall() async throws {
        let runtime = try await PluginRuntime.load(
            wasm: PluginWATFixture.wasm([[.send("a"), .send("b")]]), limits: Self.limits)
        let sent = try await runtime.handle(Data("hi".utf8))
        #expect(sent.map { String(decoding: $0, as: UTF8.self) } == ["a", "b"])
    }

    @Test(arguments: [
        ([PluginFixtureStep.trap], "unreachable"),
        ([.spin], "out of fuel"),
        ([.sendRange(ptr: 65_000, len: 1000)], "invalid memory range"),
        ([.sendRange(ptr: 0, len: 4096)], "exceeds"),
        ([.sendRepeated("x", times: 5)], "more than 4"),
    ])
    func misbehaviourSurfacesAsAnError(steps: [PluginFixtureStep], fragment: String) async throws {
        let runtime = try await PluginRuntime.load(wasm: PluginWATFixture.wasm([steps]), limits: Self.limits)
        let error = await #expect(throws: PluginRuntimeError.self) { try await runtime.handle(Data()) }
        #expect(error?.description.contains(fragment) == true)
    }

    @Test func allocPointerOutsideMemoryIsRejected() async throws {
        let runtime = try await PluginRuntime.load(
            wasm: PluginWATFixture.wasm([[]], allocReturns: 70_000), limits: Self.limits)
        let error = await #expect(throws: PluginRuntimeError.self) { try await runtime.handle(Data("hi".utf8)) }
        #expect(error == .badGuestRange(ptr: 70_000, len: 2))
    }

    @Test func importsOtherThanAlasSendFailToLoad() async throws {
        let wasm = try PluginWATFixture.wasm(
            [], extraImports: #"(import "wasi_snapshot_preview1" "fd_write" (func (param i32 i32 i32 i32) (result i32)))"#)
        await #expect(throws: PluginRuntimeError.self) { _ = try await PluginRuntime.load(wasm: wasm, limits: Self.limits) }
    }
}
```

- [ ] **Step 2: Create empty source files, regenerate, and confirm the tests fail**

Create `Alas/Sources/Plugins/PluginRuntime.swift` and `Alas/Sources/Plugins/PluginWAT.swift`, each containing only `import Foundation`. Run `xcodegen`, then the test command with `<Suite>` = `PluginRuntimeTests`.
Expected: the build fails with `cannot find 'PluginWAT' in scope` / `cannot find 'PluginRuntime' in scope`.

- [ ] **Step 3: Implement**

`Alas/Sources/Plugins/PluginWAT.swift`:

```swift
#if DEBUG
import WAT

/// Compiles WebAssembly text for test fixtures. Debug-only so Release code
/// never depends on the text format.
enum PluginWAT {
    static func compile(_ text: String) throws -> [UInt8] {
        try wat2wasm(text)
    }
}
#endif
```

`Alas/Sources/Plugins/PluginRuntime.swift`:

```swift
import Foundation
@_spi(Fuzzing) import WasmKit

struct PluginLimits: Sendable, Equatable {
    /// WasmKit cannot interrupt a running call from another thread, so fuel is
    /// the only stop for a runaway plugin. About 50 ms optimized; unoptimized
    /// (Debug) WasmKit burns fuel roughly 400x slower.
    var fuelPerCall: UInt64 = 25_000_000
    var maxMemoryBytes = 64 << 20
    var maxMessageBytes = 1 << 20
    var maxSendsPerCall = 64
}

enum PluginRuntimeError: Error, Equatable, CustomStringConvertible {
    case instantiation(String)
    case missingExport(String)
    case badGuestRange(ptr: UInt32, len: UInt32)
    case messageTooLarge(Int)
    case tooManySends(Int)
    case trap(String)

    var description: String {
        switch self {
        case .instantiation(let reason): "could not load plugin: \(reason)"
        case .missingExport(let name): "plugin does not export \(name)"
        case let .badGuestRange(ptr, len): "plugin passed an invalid memory range (ptr \(ptr), len \(len))"
        case .messageTooLarge(let size): "message of \(size) bytes exceeds the size limit"
        case .tooManySends(let limit): "plugin sent more than \(limit) messages in one call"
        case .trap(let reason): reason
        }
    }
}

private final class MemoryCap: ResourceLimiter {
    let maxBytes: Int
    init(maxBytes: Int) { self.maxBytes = maxBytes }
    func limitMemoryGrowth(to desired: Int) throws -> Bool { desired <= maxBytes }
}

/// One plugin instance. Every WasmKit call runs on `queue`, which is what makes
/// the `@unchecked Sendable` hold. This type moves bytes only; it knows nothing
/// about JSON-RPC or Alas.
final class PluginRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.nlopez.alas.plugin-runtime")
    private let limits: PluginLimits
    private let store: Store
    private var instance: Instance!
    private var outbox: [Data] = []
    private var sendFailure: PluginRuntimeError?

    private init(limits: PluginLimits) {
        self.limits = limits
        store = Store(engine: Engine(configuration: EngineConfiguration(fuelMetering: true)))
        store.resourceLimiter = MemoryCap(maxBytes: limits.maxMemoryBytes)
    }

    static func load(wasm: [UInt8], limits: PluginLimits) async throws -> PluginRuntime {
        let runtime = PluginRuntime(limits: limits)
        try await runtime.run { try runtime.instantiate(wasm) }
        return runtime
    }

    /// Delivers one message through `alas_handle`. Returns what the plugin sent
    /// with `alas.send` during the call, in order. The caller processes them
    /// after this returns, so the plugin is never re-entered.
    func handle(_ message: Data) async throws -> [Data] {
        try await run { try self.deliver(message) }
    }

    private func instantiate(_ wasm: [UInt8]) throws {
        let module: Module
        do {
            module = try parseWasm(bytes: wasm)
        } catch {
            throw PluginRuntimeError.instantiation(String(describing: error))
        }
        var imports = Imports()
        imports.define(module: "alas", name: "send", Function(store: store, parameters: [.i32, .i32]) { [unowned self] caller, args in
            try self.receive(caller, ptr: args[0].i32, len: args[1].i32)
            return []
        })
        store.fuel = Fuel(remaining: limits.fuelPerCall)
        do {
            instance = try module.instantiate(store: store, imports: imports)
        } catch {
            throw PluginRuntimeError.instantiation(Self.firstLine(error))
        }
        if instance.exports[memory: "memory"] == nil { throw PluginRuntimeError.missingExport("memory") }
        for name in ["alas_alloc", "alas_handle"] where instance.exports[function: name] == nil {
            throw PluginRuntimeError.missingExport(name)
        }
    }

    private func deliver(_ message: Data) throws -> [Data] {
        guard message.count <= limits.maxMessageBytes else {
            throw PluginRuntimeError.messageTooLarge(message.count)
        }
        outbox = []
        sendFailure = nil
        // Refill before alloc: a previous out-of-fuel trap leaves the budget empty.
        store.fuel = Fuel(remaining: limits.fuelPerCall)
        do {
            let ptr = try instance.exports[function: "alas_alloc"]!([.i32(UInt32(message.count))])[0].i32
            let memory = instance.exports[memory: "memory"]!
            // WasmKit preconditions on out-of-bounds host access, so every guest range is checked here.
            guard Int(ptr) + message.count <= memory.byteCount else {
                throw PluginRuntimeError.badGuestRange(ptr: ptr, len: UInt32(message.count))
            }
            memory.withUnsafeMutableBufferPointer(offset: UInt(ptr), count: message.count) { buffer in
                _ = message.copyBytes(to: buffer)
            }
            _ = try instance.exports[function: "alas_handle"]!([.i32(ptr), .i32(UInt32(message.count))])
        } catch {
            throw sendFailure ?? (error as? PluginRuntimeError) ?? .trap(Self.firstLine(error))
        }
        return outbox
    }

    private func receive(_ caller: borrowing Caller, ptr: UInt32, len: UInt32) throws {
        guard outbox.count < limits.maxSendsPerCall else {
            throw record(.tooManySends(limits.maxSendsPerCall))
        }
        guard Int(len) <= limits.maxMessageBytes else {
            throw record(.messageTooLarge(Int(len)))
        }
        guard let memory = caller.instance?.exports[memory: "memory"],
              Int(ptr) + Int(len) <= memory.byteCount
        else { throw record(.badGuestRange(ptr: ptr, len: len)) }
        outbox.append(memory.withUnsafeBufferPointer(offset: UInt(ptr), count: Int(len)) { Data($0) })
    }

    /// Remembers why a host call failed, in case WasmKit wraps the thrown error.
    private func record(_ error: PluginRuntimeError) -> PluginRuntimeError {
        sendFailure = error
        return error
    }

    private static func firstLine(_ error: Error) -> String {
        String(describing: error).split(separator: "\n").first.map(String.init) ?? "trap"
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }
}
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run the test command with `<Suite>` = `PluginRuntimeTests`.
Expected: `✔` for all four tests, including 5 cases of `misbehaviourSurfacesAsAnError`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Plugins/PluginRuntime.swift Alas/Sources/Plugins/PluginWAT.swift AlasTests/PluginWATFixture.swift AlasTests/PluginRuntimeTests.swift Alas.xcodeproj
git commit -m "feat(plugins): add fuel- and memory-limited Wasm plugin runtime"
```

---

### Task 4: Workspace snapshot

**Files:**
- Create: `Alas/Sources/Plugins/PluginWorkspaceSnapshot.swift`
- Test: `AlasTests/PluginWorkspaceSnapshotTests.swift`

**Interfaces:**
- Consumes: `Worktree` (`Git/GitTypes.swift`), `WorktreeDirtyState`, `AgentSidebarState`, `AgentSidebarPlanProgress`, `AgentSidebarRow` (`Right/AgentSidebarRollup.swift`).
- Produces:
  - `struct PluginWorkspaceSnapshot: Codable, Equatable, Sendable` with memberwise `init(worktrees: [WorktreeEntry])`.
  - Nested types `WorktreeEntry`, `Dirty`, `Session`, `Plan`.
  - The mapping init `init(worktrees: [WorktreeInput], selectedWorktreeId: String?)`.
  - Input types `PluginWorkspaceSnapshot.SessionInput` (`id, agent, title: String`; `state: AgentSidebarState`; `plan: AgentSidebarPlanProgress?`), with `init(row: AgentSidebarRow)`; and `PluginWorkspaceSnapshot.WorktreeInput` (`worktree: Worktree`, `dirty: WorktreeDirtyState`, `sessions: [SessionInput]`).

- [ ] **Step 1: Write the failing test**

`AlasTests/PluginWorkspaceSnapshotTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

struct PluginWorkspaceSnapshotTests {
    @Test func mapsWorktreesAndSessionsToTheWireShape() throws {
        func worktree(_ id: String, _ branch: String) -> Worktree {
            Worktree(id: id, projectId: "p", name: branch, branch: branch,
                     path: URL(fileURLWithPath: "/tmp/\(id)"), status: .clean, lastActivity: .distantPast)
        }
        let snapshot = PluginWorkspaceSnapshot(worktrees: [
            .init(worktree: worktree("a", "main"), dirty: .dirty(fileCount: 3, conflictCount: 1), sessions: [
                .init(id: "s1", agent: "claude", title: "Fix bug", state: .running,
                      plan: AgentSidebarPlanProgress(completed: 2, total: 5, currentStep: "Write test")),
            ]),
            .init(worktree: worktree("b", "feature"), dirty: .unknown, sessions: [
                .init(id: "s2", agent: "codex", title: "Review", state: .permissionRequest, plan: nil),
            ]),
        ], selectedWorktreeId: "a")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        #expect(json == #"{"worktrees":[{"branch":"main","current":true,"dirty":{"conflicts":1,"files":3},"id":"a","sessions":[{"agent":"claude","id":"s1","plan":{"completed":2,"total":5},"state":"running","title":"Fix bug"}]},{"branch":"feature","current":false,"id":"b","sessions":[{"agent":"codex","id":"s2","state":"permission_request","title":"Review"}]}]}"#)
    }
}
```

- [ ] **Step 2: Create an empty source file, regenerate, and confirm the test fails**

Create `Alas/Sources/Plugins/PluginWorkspaceSnapshot.swift` containing only `import Foundation`. Run `xcodegen`, then the test command with `<Suite>` = `PluginWorkspaceSnapshotTests`.
Expected: the build fails with `cannot find 'PluginWorkspaceSnapshot' in scope`.

- [ ] **Step 3: Implement**

`Alas/Sources/Plugins/PluginWorkspaceSnapshot.swift`:

```swift
import Foundation

/// What `workspace.read` exposes: one project's worktrees and their agent
/// sessions. Always the whole project, so plugins never reconcile diffs.
struct PluginWorkspaceSnapshot: Codable, Equatable, Sendable {
    struct WorktreeEntry: Codable, Equatable, Sendable {
        let id: String
        let branch: String
        let current: Bool
        /// Omitted until the first status scan finishes.
        let dirty: Dirty?
        let sessions: [Session]
    }

    struct Dirty: Codable, Equatable, Sendable {
        let files: Int
        let conflicts: Int
    }

    struct Session: Codable, Equatable, Sendable {
        let id: String
        let agent: String
        let title: String
        let state: String
        let plan: Plan?
    }

    struct Plan: Codable, Equatable, Sendable {
        let completed: Int
        let total: Int
    }

    let worktrees: [WorktreeEntry]
}

extension PluginWorkspaceSnapshot {
    struct SessionInput {
        let id: String
        let agent: String
        let title: String
        let state: AgentSidebarState
        let plan: AgentSidebarPlanProgress?
    }

    struct WorktreeInput {
        let worktree: Worktree
        let dirty: WorktreeDirtyState
        let sessions: [SessionInput]
    }

    init(worktrees: [WorktreeInput], selectedWorktreeId: String?) {
        self.init(worktrees: worktrees.map { input in
            let dirty: Dirty? = switch input.dirty {
            case .unknown: nil
            case .clean: Dirty(files: 0, conflicts: 0)
            case let .dirty(files, conflicts): Dirty(files: files, conflicts: conflicts)
            }
            return WorktreeEntry(
                id: input.worktree.id,
                branch: input.worktree.branch,
                current: input.worktree.id == selectedWorktreeId,
                dirty: dirty,
                sessions: input.sessions.map { session in
                    Session(
                        id: session.id, agent: session.agent, title: session.title,
                        state: Self.wireName(session.state),
                        plan: session.plan.map { Plan(completed: $0.completed, total: $0.total) })
                })
        })
    }

    static func wireName(_ state: AgentSidebarState) -> String {
        switch state {
        case .running: "running"
        case .awaitingInput: "awaiting_input"
        case .permissionRequest: "permission_request"
        case .idle: "idle"
        case .detached: "detached"
        case .unknown: "unknown"
        }
    }
}

extension PluginWorkspaceSnapshot.SessionInput {
    init(row: AgentSidebarRow) {
        let id: String = switch row.id {
        case .acp(let sessionID): sessionID
        case .terminal(_, let sessionID): sessionID
        }
        self.init(id: id, agent: row.agentID, title: row.title, state: row.state, plan: row.plan)
    }
}
```

- [ ] **Step 4: Run the test and confirm it passes**

Run the test command with `<Suite>` = `PluginWorkspaceSnapshotTests`. Expected: `✔ mapsWorktreesAndSessionsToTheWireShape()`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Plugins/PluginWorkspaceSnapshot.swift AlasTests/PluginWorkspaceSnapshotTests.swift Alas.xcodeproj
git commit -m "feat(plugins): map worktree and agent state into the plugin snapshot"
```

---

### Task 5: Protocol host

**Files:**
- Create: `Alas/Sources/Plugins/PluginMessages.swift`
- Create: `Alas/Sources/Plugins/PluginHost.swift`
- Test: `AlasTests/PluginHostTests.swift`

**Interfaces:**
- Consumes:
  - `PluginManifest`, `PluginCapability` (Task 1).
  - `PluginRuntime`, `PluginLimits` (Task 3).
  - `PluginWorkspaceSnapshot` (Task 4).
  - `PluginWATFixture`, `PluginFixtureStep` (Task 3 tests).
  - `JSONRPCEnvelope`, `JSONRPCID`, `JSONRPCError`, `AnyCodable` (`ACP/Protocol/ACPMessages.swift`).
- Produces:
  - `enum PluginHostState: Equatable, Sendable` with cases `loaded`, `activating`, `active`, `deactivating`, `stopped`, `failed(String)`.
  - `struct PluginTraceEntry: Equatable, Sendable`, with `enum Direction { case toPlugin, fromPlugin }`, `let direction`, and `let text: String`.
  - `struct PluginLogEntry: Equatable, Sendable` with `level, message: String`.
  - `@MainActor struct PluginHostActions` with `var snapshot: () -> PluginWorkspaceSnapshot` and `var switchWorktree: (String) -> Bool`, which returns false for an unknown id.
  - `struct PluginProjectRef: Codable, Equatable, Sendable` with `id, name: String`.
  - `@MainActor @Observable final class PluginHost` with:
    - `init(manifest:wasm:project:grants:actions:limits:)`;
    - `let manifest`, `let project`, `let grants: Set<PluginCapability>`;
    - `private(set) var state`, `trace`, `log`;
    - `func activate() async`, `func workspaceChanged(_ snapshot: PluginWorkspaceSnapshot) async`, and `func deactivate() async`.

- [ ] **Step 1: Write the failing tests**

`AlasTests/PluginHostTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

// File scope so `@Test(arguments:)` can read them outside the main actor.
private let activateOK = #"{"jsonrpc":"2.0","id":0,"result":{}}"#
private let switchToWT = #"{"jsonrpc":"2.0","id":1,"method":"worktree/switch","params":{"id":"wt"}}"#

/// `PluginHost` is main-actor isolated because it applies actions to AppState.
@MainActor
struct PluginHostTests {
    static let limits = PluginLimits(
        fuelPerCall: 1_000_000, maxMemoryBytes: 1 << 20, maxMessageBytes: 4096, maxSendsPerCall: 8)

    final class Recorder {
        var switched: [String] = []
    }

    func makeHost(
        _ script: [[PluginFixtureStep]],
        grants: Set<PluginCapability> = [],
        recorder: Recorder = Recorder()
    ) throws -> PluginHost {
        let manifest = try PluginManifest.parse(Data(
            #"{"id":"io.test.plugin","name":"Test","version":"1","api":1,"entry":"p.wasm"}"#.utf8))
        return PluginHost(
            manifest: manifest,
            wasm: try PluginWATFixture.wasm(script),
            project: PluginProjectRef(id: "proj", name: "Project"),
            grants: grants,
            actions: PluginHostActions(
                snapshot: { PluginWorkspaceSnapshot(worktrees: []) },
                switchWorktree: { id in
                    recorder.switched.append(id)
                    return id == "wt"
                }),
            limits: Self.limits)
    }

    func lastReply(_ host: PluginHost) -> String? {
        host.trace.last { $0.direction == .toPlugin }?.text
    }

    @Test func activationHandshakeMakesTheHostActive() async throws {
        let host = try makeHost([[.send(activateOK)]])
        await host.activate()
        #expect(host.state == .active)
    }

    @Test(arguments: [
        ([PluginFixtureStep](), "did not respond to alas/activate"),
        ([.send(#"{"jsonrpc":"2.0","id":0,"error":{"code":1,"message":"nope"}}"#)], "rejected activation: nope"),
        ([.send("{not json")], "malformed"),
        ([.trap], "unreachable"),
    ])
    func activationFailuresStopThePlugin(steps: [PluginFixtureStep], fragment: String) async throws {
        let host = try makeHost([steps])
        await host.activate()
        guard case .failed(let reason) = host.state else {
            Issue.record("expected failed, got \(host.state)")
            return
        }
        #expect(reason.contains(fragment))
    }

    @Test(arguments: [
        (switchToWT, Set<PluginCapability>(), #""code":-32001"#, [String]()),
        (switchToWT, [.worktreeSwitch], #""result":{}"#, ["wt"]),
        (#"{"jsonrpc":"2.0","id":1,"method":"worktree/switch","params":{"id":"gone"}}"#, [.worktreeSwitch], #""code":-32003"#, ["gone"]),
        (#"{"jsonrpc":"2.0","id":1,"method":"worktree/switch","params":{}}"#, [.worktreeSwitch], #""code":-32602"#, []),
        (#"{"jsonrpc":"2.0","id":1,"method":"nope/x"}"#, [.worktreeSwitch], #""code":-32601"#, []),
    ])
    func requestsAreCheckedAgainstGrants(
        request: String, grants: Set<PluginCapability>, expectedReply: String, expectedSwitches: [String]
    ) async throws {
        let recorder = Recorder()
        let host = try makeHost([[.send(activateOK), .send(request)]], grants: grants, recorder: recorder)
        await host.activate()
        #expect(host.state == .active)
        #expect(recorder.switched == expectedSwitches)
        #expect(lastReply(host)?.contains(expectedReply) == true)
    }

    @Test(arguments: [(Set<PluginCapability>(), 0), ([.workspaceRead], 1)])
    func workspaceChangesNeedTheReadGrant(grants: Set<PluginCapability>, deliveries: Int) async throws {
        let host = try makeHost([[.send(activateOK)]], grants: grants)
        await host.activate()
        await host.workspaceChanged(PluginWorkspaceSnapshot(worktrees: []))
        let changed = host.trace.filter { $0.direction == .toPlugin && $0.text.contains("workspace/changed") }
        #expect(changed.count == deliveries)
    }

    @Test func strayResponsesAreIgnored() async throws {
        let host = try makeHost([[
            .send(activateOK),
            .send(activateOK),
            .send(#"{"jsonrpc":"2.0","id":99,"result":{}}"#),
        ]])
        await host.activate()
        #expect(host.state == .active)
    }

    @Test func deactivationIgnoresWhatThePluginSendsBack() async throws {
        let recorder = Recorder()
        let host = try makeHost(
            [[.send(activateOK)], [.send(switchToWT)]], grants: [.worktreeSwitch], recorder: recorder)
        await host.activate()
        await host.deactivate()
        #expect(host.state == .stopped)
        #expect(recorder.switched.isEmpty)
    }
}
```

- [ ] **Step 2: Create empty source files, regenerate, and confirm the tests fail**

Create `Alas/Sources/Plugins/PluginMessages.swift` and `Alas/Sources/Plugins/PluginHost.swift`, each containing only `import Foundation`. Run `xcodegen`, then the test command with `<Suite>` = `PluginHostTests`.
Expected: the build fails with `cannot find 'PluginHost' in scope`.

- [ ] **Step 3: Implement the wire types**

`Alas/Sources/Plugins/PluginMessages.swift`:

```swift
import Foundation

// JSON-RPC 2.0 payloads for plugin API v1. Envelopes reuse `JSONRPCEnvelope`,
// `JSONRPCID`, and `JSONRPCError` from the ACP protocol layer.

struct PluginProjectRef: Codable, Equatable, Sendable {
    let id: String
    let name: String
}

struct PluginActivateParams: Codable, Equatable, Sendable {
    let api: Int
    let project: PluginProjectRef
    let grants: [PluginCapability]
}

/// `workspace/snapshot` result and `workspace/changed` params.
struct PluginSnapshotPayload: Codable, Equatable, Sendable {
    let snapshot: PluginWorkspaceSnapshot
}

struct PluginWorktreeSwitchParams: Codable, Equatable, Sendable {
    let id: String
}

struct PluginLogParams: Codable, Equatable, Sendable {
    let level: String
    let message: String
}

/// Encodes as `{}`.
struct PluginEmptyPayload: Codable, Equatable, Sendable {}

struct PluginResponse<Result: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: JSONRPCID
    let result: Result?
    let error: JSONRPCError?
}

/// Enough of any incoming message to route it. Params are decoded separately
/// with `PluginParams` once the method is known.
struct PluginIncomingHeader: Decodable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String?
    let error: JSONRPCError?
}

struct PluginParams<Params: Decodable>: Decodable {
    let params: Params
}
```

- [ ] **Step 4: Implement the host**

`Alas/Sources/Plugins/PluginHost.swift`:

```swift
import Foundation
import Observation

enum PluginHostState: Equatable, Sendable {
    case loaded
    case activating
    case active
    case deactivating
    case stopped
    case failed(String)
}

struct PluginTraceEntry: Equatable, Sendable {
    enum Direction: Sendable {
        case toPlugin
        case fromPlugin
    }

    let direction: Direction
    let text: String
}

struct PluginLogEntry: Equatable, Sendable {
    let level: String
    let message: String
}

/// What a plugin may ask Alas to do, already scoped to one project.
@MainActor
struct PluginHostActions {
    var snapshot: () -> PluginWorkspaceSnapshot
    /// Returns false when `id` is not a worktree of this project.
    var switchWorktree: (String) -> Bool
}

/// Runs the v1 protocol for one plugin in one project.
@MainActor
@Observable
final class PluginHost {
    static let apiVersion = 1
    private static let activateID = JSONRPCID.number(0)
    private static let requiredCapability: [String: PluginCapability] = [
        "workspace/snapshot": .workspaceRead,
        "worktree/switch": .worktreeSwitch,
    ]
    private static let traceLimit = 100
    private static let logLimit = 200

    let manifest: PluginManifest
    let project: PluginProjectRef
    let grants: Set<PluginCapability>
    private(set) var state: PluginHostState = .loaded
    private(set) var trace: [PluginTraceEntry] = []
    private(set) var log: [PluginLogEntry] = []

    @ObservationIgnored private let wasm: [UInt8]
    @ObservationIgnored private let actions: PluginHostActions
    @ObservationIgnored private let limits: PluginLimits
    @ObservationIgnored private var runtime: PluginRuntime?

    init(
        manifest: PluginManifest,
        wasm: [UInt8],
        project: PluginProjectRef,
        grants: Set<PluginCapability>,
        actions: PluginHostActions,
        limits: PluginLimits = PluginLimits()
    ) {
        self.manifest = manifest
        self.wasm = wasm
        self.project = project
        self.grants = grants
        self.actions = actions
        self.limits = limits
    }

    private var isRunning: Bool { state == .activating || state == .active }

    /// Starts a fresh instance. Also used to restart after `stopped` or `failed`.
    func activate() async {
        guard !isRunning, state != .deactivating else { return }
        state = .activating
        trace = []
        do {
            runtime = try await PluginRuntime.load(wasm: wasm, limits: limits)
        } catch {
            fail(String(describing: error))
            return
        }
        let params = PluginActivateParams(
            api: Self.apiVersion, project: project,
            grants: grants.sorted { $0.rawValue < $1.rawValue })
        await deliver(encode(JSONRPCEnvelope(id: Self.activateID, method: "alas/activate", params: params)))
        if state == .activating {
            fail("plugin did not respond to alas/activate")
        }
    }

    func workspaceChanged(_ snapshot: PluginWorkspaceSnapshot) async {
        guard state == .active, grants.contains(.workspaceRead) else { return }
        await deliver(encode(JSONRPCEnvelope(
            id: nil, method: "workspace/changed", params: PluginSnapshotPayload(snapshot: snapshot))))
    }

    /// Sends `alas/deactivate`, then drops the instance whatever the plugin does.
    /// Anything the plugin sends back is ignored.
    func deactivate() async {
        guard isRunning, let runtime else {
            self.runtime = nil
            return
        }
        state = .deactivating
        let message = encode(JSONRPCEnvelope<PluginEmptyPayload>(id: nil, method: "alas/deactivate", params: nil))
        record(.toPlugin, message)
        _ = try? await runtime.handle(message)
        self.runtime = nil
        state = .stopped
    }

    // MARK: - Delivery

    private enum Outcome {
        case none
        case reply(Data)
        case violation(String)
    }

    /// Delivers `first`, then any replies to requests the plugin made, each in
    /// its own `alas_handle` call. Stops as soon as the host leaves the running
    /// states, which drops everything still queued.
    private func deliver(_ first: Data) async {
        var queue = [first]
        while !queue.isEmpty, isRunning, let runtime {
            let message = queue.removeFirst()
            record(.toPlugin, message)
            let sent: [Data]
            do {
                sent = try await runtime.handle(message)
            } catch {
                fail(String(describing: error))
                return
            }
            for data in sent {
                guard isRunning, self.runtime === runtime else { return }
                record(.fromPlugin, data)
                switch process(data) {
                case .none: break
                case .reply(let reply): queue.append(reply)
                case .violation(let reason):
                    fail(reason)
                    return
                }
            }
        }
    }

    private func process(_ data: Data) -> Outcome {
        guard let header = try? JSONDecoder().decode(PluginIncomingHeader.self, from: data),
              header.jsonrpc == "2.0"
        else { return .violation("plugin sent a malformed message") }
        switch (header.method, header.id) {
        case let (method?, id?):
            return .reply(handleRequest(method, id: id, data: data))
        case let (method?, nil):
            handleNotification(method, data: data)
            return .none
        case let (nil, id?):
            handleResponse(id: id, error: header.error)
            return .none
        case (nil, nil):
            return .violation("plugin sent a malformed message")
        }
    }

    private func handleRequest(_ method: String, id: JSONRPCID, data: Data) -> Data {
        guard let capability = Self.requiredCapability[method] else {
            return errorReply(id, code: -32601, "method not found: \(method)")
        }
        guard grants.contains(capability) else {
            return errorReply(id, code: -32001, "capability not granted: \(capability.rawValue)")
        }
        switch method {
        case "workspace/snapshot":
            return encode(PluginResponse(
                id: id, result: PluginSnapshotPayload(snapshot: actions.snapshot()), error: nil))
        case "worktree/switch":
            guard let params = try? JSONDecoder().decode(PluginParams<PluginWorktreeSwitchParams>.self, from: data).params else {
                return errorReply(id, code: -32602, "invalid params for \(method)")
            }
            guard actions.switchWorktree(params.id) else {
                return errorReply(id, code: -32003, "unknown worktree \(params.id)")
            }
            return encode(PluginResponse(id: id, result: PluginEmptyPayload(), error: nil))
        default:
            return errorReply(id, code: -32601, "method not found: \(method)")
        }
    }

    /// Notifications never get replies, so bad ones are dropped.
    private func handleNotification(_ method: String, data: Data) {
        guard method == "log",
              let params = try? JSONDecoder().decode(PluginParams<PluginLogParams>.self, from: data).params
        else { return }
        appendLog(params.level, params.message)
    }

    /// Only the activation response matters in v1. Anything else is stray and ignored.
    private func handleResponse(id: JSONRPCID, error: JSONRPCError?) {
        guard id == Self.activateID, state == .activating else { return }
        if let error {
            fail("plugin rejected activation: \(error.message)")
        } else {
            state = .active
        }
    }

    // MARK: - Helpers

    private func fail(_ reason: String) {
        state = .failed(reason)
        runtime = nil
        appendLog("error", reason)
    }

    private func appendLog(_ level: String, _ message: String) {
        log.append(PluginLogEntry(level: level, message: message))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    private func record(_ direction: PluginTraceEntry.Direction, _ data: Data) {
        trace.append(PluginTraceEntry(direction: direction, text: String(decoding: data.prefix(2000), as: UTF8.self)))
        if trace.count > Self.traceLimit { trace.removeFirst(trace.count - Self.traceLimit) }
    }

    private func errorReply(_ id: JSONRPCID, code: Int, _ message: String) -> Data {
        encode(PluginResponse<PluginEmptyPayload>(
            id: id, result: nil, error: JSONRPCError(code: code, message: message, data: nil)))
    }

    private func encode(_ value: some Encodable) -> Data {
        // Our own payload types always encode.
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run the test command with `<Suite>` = `PluginHostTests`.
Expected: `✔` for all six tests, and `** TEST SUCCEEDED **`.

If `requestsAreCheckedAgainstGrants` fails on `lastReply`, print the trace (`Issue.record("\(host.trace)")`) to check the encoder's key spelling before changing any assertion.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/Plugins/PluginMessages.swift Alas/Sources/Plugins/PluginHost.swift AlasTests/PluginHostTests.swift Alas.xcodeproj
git commit -m "feat(plugins): add JSON-RPC plugin host with capability checks"
```

---

### Task 6: Manager, AppState adapter, and Debug window

**Files:**
- Create: `Alas/Sources/Plugins/PluginManager.swift`
- Create: `Alas/Sources/Plugins/AppState+Plugins.swift`
- Create: `Alas/Sources/Plugins/PluginsWindow.swift`
- Delete: `Alas/Sources/Plugins/PluginPrototypeRuntime.swift`, `Alas/Sources/Plugins/PluginPrototypeWindow.swift`
- Modify: `Alas/Sources/App/AlasApp.swift` (the `Plugin Prototype…` button in the `#if DEBUG` `CommandMenu("Debug")`)
- Test: `AlasTests/PluginManagerDiscoveryTests.swift`

**Interfaces:**
- Consumes: everything above.
- Consumes from `AppState`:
  - `projects: [ProjectConfig]`
  - `projectsManager.worktreesByProject: [String: [Worktree]]`
  - `selectedWorktreeId: String?`
  - `agentSidebarRollup(for: Worktree) -> AgentSidebarRollup`
  - `focusGlobalWorktree(id:projectId:)`
  - `WorktreeStatusStore.shared.status(forPath:)`
- Produces:
  - `@MainActor @Observable final class PluginManager` with:
    - `static var defaultDirectory: URL`;
    - `nonisolated static func discover(in: URL) -> (plugins: [PluginManager.Plugin], invalid: [PluginManager.Invalid])`;
    - `func reload() async`, `func approve(_:) async`, `func restart(_:) async`;
    - `func isApproved(_:) -> Bool`, `func hosts(for:) -> [(key: HostKey, host: PluginHost)]`.
  - `extension AppState { func pluginHostActions(for project: ProjectConfig) -> PluginHostActions }`.
  - `PluginsWindowController.shared.show(state:)`.

- [ ] **Step 1: Write the failing discovery test**

`AlasTests/PluginManagerDiscoveryTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

struct PluginManagerDiscoveryTests {
    @Test func invalidAndDuplicateFoldersAreReportedAndNotLoaded() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PluginDiscovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func install(_ folder: String, id: String, wasm: Bool = true) throws {
            let dir = root.appending(path: folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"{"id":"\#(id)","name":"N","version":"1","api":1,"entry":"plugin.wasm"}"#.utf8)
                .write(to: dir.appending(path: "plugin.json"))
            if wasm { try Data([0]).write(to: dir.appending(path: "plugin.wasm")) }
        }
        try install("good", id: "io.x.good")
        try install("no-wasm", id: "io.x.nowasm", wasm: false)
        try install("dup-a", id: "io.x.dup")
        try install("dup-b", id: "io.x.dup")

        let result = PluginManager.discover(in: root)

        #expect(result.plugins.map(\.id) == ["io.x.good"])
        #expect(Set(result.invalid.map(\.folder.lastPathComponent)) == ["no-wasm", "dup-a", "dup-b"])
    }
}
```

- [ ] **Step 2: Create an empty `PluginManager.swift`, regenerate, and confirm the test fails**

Create `Alas/Sources/Plugins/PluginManager.swift` containing only `import Foundation`. Run `xcodegen`, then the test command with `<Suite>` = `PluginManagerDiscoveryTests`.
Expected: the build fails with `cannot find 'PluginManager' in scope`.

- [ ] **Step 3: Implement the manager**

`Alas/Sources/Plugins/PluginManager.swift`:

```swift
import Foundation
import Observation

/// Discovers plugins, holds approvals, and runs one `PluginHost` per approved
/// plugin per project.
@MainActor
@Observable
final class PluginManager {
    struct Plugin: Identifiable, Sendable {
        let folder: URL
        let manifest: PluginManifest
        let wasm: [UInt8]
        let hash: String
        var id: String { manifest.id }
    }

    struct Invalid: Identifiable, Sendable {
        let folder: URL
        let reason: String
        var id: String { folder.path }
    }

    struct HostKey: Hashable, Sendable {
        let pluginID: String
        let projectID: String
    }

    static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return appSupport.appending(path: "Alas/Plugins")
    }

    private(set) var plugins: [Plugin] = []
    private(set) var invalid: [Invalid] = []
    private(set) var hostsByKey: [HostKey: PluginHost] = [:]

    @ObservationIgnored let directory: URL
    @ObservationIgnored private let approvals: PluginApprovalStore
    @ObservationIgnored private let projects: () -> [ProjectConfig]
    @ObservationIgnored private let actions: (ProjectConfig) -> PluginHostActions
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var lastSnapshots: [HostKey: PluginWorkspaceSnapshot] = [:]

    init(
        directory: URL = PluginManager.defaultDirectory,
        approvals: PluginApprovalStore = PluginApprovalStore(),
        projects: @escaping () -> [ProjectConfig],
        actions: @escaping (ProjectConfig) -> PluginHostActions
    ) {
        self.directory = directory
        self.approvals = approvals
        self.projects = projects
        self.actions = actions
    }

    func isApproved(_ plugin: Plugin) -> Bool {
        approvals.approval(id: plugin.id, hash: plugin.hash) != nil
    }

    func hosts(for plugin: Plugin) -> [(key: HostKey, host: PluginHost)] {
        hostsByKey.filter { $0.key.pluginID == plugin.id }
            .map { (key: $0.key, host: $0.value) }
            .sorted { $0.host.project.name < $1.host.project.name }
    }

    /// Stops everything, rescans the folder, and starts approved plugins for
    /// every project. Projects added later need another reload (Debug-only for now).
    func reload() async {
        snapshotTask?.cancel()
        for host in hostsByKey.values { await host.deactivate() }
        hostsByKey = [:]
        lastSnapshots = [:]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        (plugins, invalid) = Self.discover(in: directory)
        for plugin in plugins where isApproved(plugin) { await start(plugin) }
        startSnapshotLoop()
    }

    func approve(_ plugin: Plugin) async {
        approvals.approve(PluginApproval(id: plugin.id, hash: plugin.hash, capabilities: plugin.manifest.capabilities))
        await start(plugin)
    }

    func restart(_ key: HostKey) async {
        guard let host = hostsByKey[key] else { return }
        await host.deactivate()
        lastSnapshots[key] = nil
        await host.activate()
    }

    private func start(_ plugin: Plugin) async {
        guard let approval = approvals.approval(id: plugin.id, hash: plugin.hash) else { return }
        for project in projects() {
            let key = HostKey(pluginID: plugin.id, projectID: project.id)
            guard hostsByKey[key] == nil else { continue }
            let host = PluginHost(
                manifest: plugin.manifest, wasm: plugin.wasm,
                project: PluginProjectRef(id: project.id, name: project.name),
                grants: Set(approval.capabilities), actions: actions(project))
            hostsByKey[key] = host
            await host.activate()
        }
    }

    // ponytail: polls every 500 ms and diffs, because agent state mixes ObservableObject
    // and @Observable sources; switch to change notifications if the rebuild shows up in profiles.
    private func startSnapshotLoop() {
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pushChangedSnapshots()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func pushChangedSnapshots() async {
        let projectsByID = Dictionary(projects().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, host) in hostsByKey where host.state == .active && host.grants.contains(.workspaceRead) {
            guard let project = projectsByID[key.projectID] else { continue }
            let snapshot = actions(project).snapshot()
            guard snapshot != lastSnapshots[key] else { continue }
            lastSnapshots[key] = snapshot
            await host.workspaceChanged(snapshot)
        }
    }

    /// Every sub-folder with a `plugin.json`. Folders that fail validation, and
    /// all folders sharing a duplicate id, are reported instead of loaded.
    nonisolated static func discover(in directory: URL) -> (plugins: [Plugin], invalid: [Invalid]) {
        let fileManager = FileManager.default
        let folders = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.resolvingSymlinksInPath() }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path < $1.path }
        var found: [Plugin] = []
        var invalid: [Invalid] = []
        for folder in folders {
            do {
                let manifestData = try Data(contentsOf: folder.appending(path: "plugin.json"))
                let manifest = try PluginManifest.parse(manifestData)
                let entry = folder.appending(path: manifest.entry)
                guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    throw PluginManifestError.invalidEntry(manifest.entry)
                }
                let wasm = try Data(contentsOf: entry)
                found.append(Plugin(
                    folder: folder, manifest: manifest, wasm: [UInt8](wasm),
                    hash: PluginTrust.hash(manifest: manifestData, wasm: wasm)))
            } catch {
                invalid.append(Invalid(folder: folder, reason: String(describing: error)))
            }
        }
        let duplicateIDs = Set(Dictionary(grouping: found, by: \.id).filter { $0.value.count > 1 }.keys)
        invalid += found.filter { duplicateIDs.contains($0.id) }
            .map { Invalid(folder: $0.folder, reason: "duplicate plugin id \($0.id)") }
        return (found.filter { !duplicateIDs.contains($0.id) }, invalid)
    }
}
```

- [ ] **Step 4: Run the discovery test and confirm it passes**

Run `xcodegen`, then the test command with `<Suite>` = `PluginManagerDiscoveryTests`.
Expected: `✔ invalidAndDuplicateFoldersAreReportedAndNotLoaded()`.

- [ ] **Step 5: Add the AppState adapter**

`Alas/Sources/Plugins/AppState+Plugins.swift`:

```swift
import Foundation

extension AppState {
    /// Plugin actions scoped to `project`: a snapshot of its worktrees, and
    /// switching only to worktrees that belong to it.
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
            })
    }

    private func pluginWorkspaceSnapshot(projectId: String) -> PluginWorkspaceSnapshot {
        let worktrees = projectsManager.worktreesByProject[projectId] ?? []
        return PluginWorkspaceSnapshot(
            worktrees: worktrees.map { worktree in
                PluginWorkspaceSnapshot.WorktreeInput(
                    worktree: worktree,
                    dirty: WorktreeStatusStore.shared.status(forPath: worktree.path.path),
                    sessions: agentSidebarRollup(for: worktree).active.map(PluginWorkspaceSnapshot.SessionInput.init(row:)))
            },
            selectedWorktreeId: selectedWorktreeId)
    }
}
```

- [ ] **Step 6: Replace the prototype window with Debug → Plugins…**

Delete the prototype:

```bash
git rm Alas/Sources/Plugins/PluginPrototypeRuntime.swift Alas/Sources/Plugins/PluginPrototypeWindow.swift
```

Create `Alas/Sources/Plugins/PluginsWindow.swift`:

```swift
#if DEBUG
import AppKit
import SwiftUI

struct PluginsView: View {
    let manager: PluginManager

    var body: some View {
        List {
            Section("Folder") {
                HStack {
                    Text(manager.directory.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([manager.directory]) }
                    Button("Reload") { Task { await manager.reload() } }
                }
            }
            ForEach(manager.plugins) { plugin in
                Section("\(plugin.manifest.name) \(plugin.manifest.version) · \(plugin.id)") {
                    if manager.isApproved(plugin) {
                        ForEach(manager.hosts(for: plugin), id: \.key) { entry in
                            PluginHostRow(host: entry.host) { Task { await manager.restart(entry.key) } }
                        }
                    } else {
                        Text(plugin.manifest.capabilities.isEmpty ? "Requests no capabilities." : "Requests:")
                        ForEach(plugin.manifest.capabilities, id: \.self) { capability in
                            Text("• \(capability.summary)")
                        }
                        Button("Approve and run") { Task { await manager.approve(plugin) } }
                    }
                }
            }
            if !manager.invalid.isEmpty {
                Section("Not loaded") {
                    ForEach(manager.invalid) { entry in
                        Text("\(entry.folder.lastPathComponent): \(entry.reason)")
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

struct PluginHostRow: View {
    let host: PluginHost
    let restart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(host.project.name).bold()
                Text(Self.label(host.state)).foregroundStyle(.secondary)
                Spacer()
                Button("Restart", action: restart)
            }
            ForEach(Array(host.log.suffix(5).enumerated()), id: \.offset) { _, entry in
                Text("[\(entry.level)] \(entry.message)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            DisclosureGroup("Messages (\(host.trace.count))") {
                ForEach(Array(host.trace.suffix(20).enumerated()), id: \.offset) { _, entry in
                    Text("\(entry.direction == .toPlugin ? "→" : "←") \(entry.text)")
                        .font(.caption.monospaced())
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
    }

    static func label(_ state: PluginHostState) -> String {
        switch state {
        case .loaded: "loaded"
        case .activating: "activating"
        case .active: "active"
        case .deactivating: "deactivating"
        case .stopped: "stopped"
        case .failed(let reason): "Plugin stopped: \(reason)"
        }
    }
}

/// Owns the plugin manager for Phase 2: plugins start the first time this
/// window opens and keep running after it closes, until the app quits.
@MainActor
final class PluginsWindowController: NSObject, NSWindowDelegate {
    static let shared = PluginsWindowController()
    private var window: NSWindow?
    private var manager: PluginManager?

    func show(state: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let manager = self.manager ?? makeManager(state: state)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.title = "Plugins"
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: PluginsView(manager: manager))
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private func makeManager(state: AppState) -> PluginManager {
        let manager = PluginManager(
            projects: { [weak state] in state?.projects ?? [] },
            actions: { [weak state] project in
                state?.pluginHostActions(for: project)
                    ?? PluginHostActions(snapshot: { PluginWorkspaceSnapshot(worktrees: []) }, switchWorktree: { _ in false })
            })
        self.manager = manager
        Task { await manager.reload() }
        return manager
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === window {
            window = nil
        }
    }
}
#endif
```

In `Alas/Sources/App/AlasApp.swift`, replace:

```swift
            Button("Plugin Prototype…") {
                PluginPrototypeWindowController.shared.show()
            }
```

with:

```swift
            Button("Plugins…") {
                PluginsWindowController.shared.show(state: state)
            }
```

- [ ] **Step 7: Regenerate and build**

```bash
xcodegen
export ALAS_FFF_TARGET_ARCH=arm64 ALAS_ZMX_TARGET_ARCH=arm64 ALAS_ZMX_OPTIONAL=1
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' \
  -configuration Debug ONLY_ACTIVE_ARCH=YES ARCHS=arm64 build > /tmp/alas-build.log 2>&1; echo EXIT=$?
grep -E "\*\* BUILD" /tmp/alas-build.log; grep "Plugins/" /tmp/alas-build.log | grep -E "warning|error" | sort -u
```

Expected: `EXIT=0`, `** BUILD SUCCEEDED **`, and no warnings from `Plugins/`.

- [ ] **Step 8: Run all plugin suites together**

Run the test command once for each suite: `PluginManifestTests`, `PluginTrustTests`, `PluginRuntimeTests`, `PluginWorkspaceSnapshotTests`, `PluginHostTests`, `PluginManagerDiscoveryTests`. Or pass six `-only-testing` flags in a single `xcodebuild` invocation.
Expected: all `✔`.

- [ ] **Step 9: Commit**

```bash
git add -A Alas/Sources/Plugins Alas/Sources/App/AlasApp.swift AlasTests/PluginManagerDiscoveryTests.swift Alas.xcodeproj
git commit -m "feat(plugins): discover, approve, and run plugins from Debug > Plugins"
```

---

### Task 7: Rust sample, API reference, and exit check

**Files:**
- Create: `plugins/samples/hello-workspace/Cargo.toml`
- Create: `plugins/samples/hello-workspace/src/lib.rs`
- Create: `plugins/samples/hello-workspace/plugin.json`
- Create: `plugins/samples/hello-workspace/build.sh`
- Create: `plugins/samples/hello-workspace/.gitignore`
- Create: `docs/plugins/api-v1.md`

**Interfaces:**
- Consumes: the wire contract from Tasks 1–5. It implements the guest side: exports `memory`, `alas_alloc`, `alas_handle`, and imports `alas.send`.

- [ ] **Step 1: Install the wasm target**

Run: `rustup target add wasm32-unknown-unknown`
Expected: `installed` or `up to date`.

- [ ] **Step 2: Write the crate**

`plugins/samples/hello-workspace/Cargo.toml`:

```toml
[package]
name = "hello-workspace"
version = "0.1.0"
edition = "2021"
publish = false

# Standalone: not part of any parent workspace.
[workspace]

[lib]
crate-type = ["cdylib"]

[dependencies]
serde_json = "1"

[profile.release]
opt-level = "s"
lto = true
strip = true
panic = "abort"
```

`plugins/samples/hello-workspace/.gitignore`:

```
target/
```

`plugins/samples/hello-workspace/plugin.json`:

```json
{
  "id": "io.nlopez.hello-workspace",
  "name": "Hello Workspace",
  "version": "0.1.0",
  "api": 1,
  "entry": "plugin.wasm",
  "capabilities": ["workspace.read"]
}
```

`plugins/samples/hello-workspace/src/lib.rs`:

```rust
//! Minimal Alas plugin (API v1). Logs a summary of the project's worktrees and
//! agent sessions, and deliberately calls `worktree/switch` without the
//! capability to show the denial path.

use serde_json::{json, Value};

#[link(wasm_import_module = "alas")]
extern "C" {
    #[link_name = "send"]
    fn alas_send(ptr: *const u8, len: usize);
}

fn send(message: Value) {
    let text = message.to_string();
    unsafe { alas_send(text.as_ptr(), text.len()) }
}

fn log(level: &str, message: String) {
    send(json!({"jsonrpc": "2.0", "method": "log", "params": {"level": level, "message": message}}));
}

fn request(id: i64, method: &str, params: Value) {
    send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
}

fn summary(snapshot: &Value) -> String {
    let empty = Vec::new();
    let worktrees = snapshot["worktrees"].as_array().unwrap_or(&empty);
    let sessions: Vec<&Value> = worktrees
        .iter()
        .flat_map(|worktree| worktree["sessions"].as_array().unwrap_or(&empty).iter())
        .collect();
    let running = sessions.iter().filter(|session| session["state"] == "running").count();
    format!("{} worktrees, {} sessions ({} running)", worktrees.len(), sessions.len(), running)
}

/// Alas writes each incoming message into a buffer allocated here.
/// `alas_handle` takes ownership and frees it.
#[no_mangle]
pub extern "C" fn alas_alloc(len: usize) -> *mut u8 {
    Box::into_raw(vec![0u8; len].into_boxed_slice()) as *mut u8
}

/// # Safety
/// `ptr`/`len` must come from `alas_alloc`; Alas guarantees this.
#[no_mangle]
pub unsafe extern "C" fn alas_handle(ptr: *mut u8, len: usize) {
    let bytes = Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len));
    let Ok(message) = serde_json::from_slice::<Value>(&bytes) else { return };
    match message["method"].as_str() {
        Some("alas/activate") => {
            send(json!({"jsonrpc": "2.0", "id": message["id"], "result": {}}));
            log("info", format!("activated for {}", message["params"]["project"]["name"]));
            request(1, "workspace/snapshot", json!({}));
            request(2, "worktree/switch", json!({"id": "any"}));
        }
        Some("workspace/changed") => {
            log("info", format!("changed: {}", summary(&message["params"]["snapshot"])));
        }
        Some(_) => {}
        None => match message["id"].as_i64() {
            Some(1) => log("info", format!("snapshot: {}", summary(&message["result"]["snapshot"]))),
            Some(2) => log("warn", format!("worktree/switch replied {}", message["error"])),
            _ => {}
        },
    }
}
```

`plugins/samples/hello-workspace/build.sh`:

```bash
#!/usr/bin/env bash
# Builds the sample and installs it into the Alas plugins folder.
set -euo pipefail
cd "$(dirname "$0")"
cargo build --release --target wasm32-unknown-unknown
dest="$HOME/Library/Application Support/Alas/Plugins/hello-workspace"
mkdir -p "$dest"
cp plugin.json "$dest/plugin.json"
cp target/wasm32-unknown-unknown/release/hello_workspace.wasm "$dest/plugin.wasm"
echo "Installed to $dest"
```

Then run `chmod +x plugins/samples/hello-workspace/build.sh`.

- [ ] **Step 3: Build the sample**

Run: `plugins/samples/hello-workspace/build.sh`
Expected: `Installed to …/Alas/Plugins/hello-workspace`. `Cargo.lock` is created; commit it.

- [ ] **Step 4: Write the API reference**

`docs/plugins/api-v1.md`:

````markdown
# Alas plugin API v1

Alas plugins are WebAssembly modules that talk to Alas with JSON-RPC 2.0
messages. They have no filesystem, network, environment, or clock access. All
they can do is send messages, and Alas answers requests only for capabilities
the user approved.

## Installing

Put a folder in `~/Library/Application Support/Alas/Plugins/` containing
`plugin.json` and the wasm file it names. A symlinked folder works too. Open
**Debug → Plugins…**, then choose **Approve and run**. If you change either
file, the plugin needs approval again.

## Manifest

```json
{
  "id": "io.example.my-plugin",
  "name": "My Plugin",
  "version": "0.1.0",
  "api": 1,
  "entry": "plugin.wasm",
  "capabilities": ["workspace.read"]
}
```

| Field | Rule |
|---|---|
| `id` | Reverse-DNS: lowercase letters, digits, `-`, and at least one dot. Unique across installed plugins. |
| `name`, `version` | Non-empty strings. |
| `api` | Must be `1`. Anything else fails with `requires plugin API N; this Alas supports 1`. |
| `entry` | Relative path to the wasm file inside the plugin folder. |
| `capabilities` | Optional. Each must be one of the capabilities below; an unknown name rejects the plugin. |

Unknown fields are ignored.

## Wasm ABI

The module must export:

- `memory`
- `alas_alloc(len: i32) -> i32`: returns a buffer of `len` bytes. Alas writes
  one incoming message there. The plugin owns the buffer and must free it.
- `alas_handle(ptr: i32, len: i32)`: handles one message.

The module may import only `alas.send(ptr: i32, len: i32)`, which sends one
message to Alas. Any other import, including WASI, fails to load.

Messages sent during `alas_handle` are processed after it returns. Alas never
calls into a plugin while the plugin is running. A response to a plugin request
arrives in a later `alas_handle` call.

## Lifecycle

1. Alas sends `alas/activate` with id `0` and params
   `{api, project: {id, name}, grants: [capability]}`.
   The plugin must reply `{"jsonrpc":"2.0","id":0,"result":{}}` **during the
   same call**. A missing or error reply stops the plugin.
2. While active, the plugin receives notifications and responses.
3. Alas sends the notification `alas/deactivate` when the project closes, the
   plugin is disabled or reloaded, or the app quits. Anything sent in reply is
   ignored.

A plugin runs once per project. Its instances share nothing.

## Methods

| Direction | Method | Kind | Capability |
|---|---|---|---|
| Alas → plugin | `alas/activate` | request | none |
| Alas → plugin | `alas/deactivate` | notification | none |
| Alas → plugin | `workspace/changed` `{snapshot}` | notification, at most 2 per second | `workspace.read` |
| plugin → Alas | `workspace/snapshot` → `{snapshot}` | request | `workspace.read` |
| plugin → Alas | `worktree/switch` `{id}` → `{}` | request | `worktree.switch` |
| plugin → Alas | `log` `{level, message}` | notification | none |

`level` is `debug`, `info`, `warn`, or `error`. Unknown notifications and stray
responses are ignored.

### Snapshot

```json
{
  "worktrees": [{
    "id": "…", "branch": "main", "current": true,
    "dirty": { "files": 3, "conflicts": 0 },
    "sessions": [{
      "id": "…", "agent": "claude", "title": "…",
      "state": "running",
      "plan": { "completed": 2, "total": 5 }
    }]
  }]
}
```

- `state` is one of `running`, `awaiting_input`, `permission_request`, `idle`,
  or `unknown`.
- `dirty` is omitted until Alas has scanned the worktree.
- `plan` is omitted when a session has no plan.

## Capabilities

| Capability | Grants |
|---|---|
| `workspace.read` | `workspace/snapshot` and `workspace/changed` for the plugin's project |
| `worktree.switch` | `worktree/switch` to a worktree of the plugin's project |

## Errors

| Code | Meaning |
|---|---|
| `-32601` | Unknown method |
| `-32602` | Invalid params |
| `-32001` | Capability not granted |
| `-32003` | Action failed, for example an unknown worktree id |

## Limits

Exceeding any of these limits stops the plugin with a reason. The memory limit
is the exception: `memory.grow` just returns `-1`.

| Limit | Value |
|---|---|
| Execution per `alas_handle` call | 25,000,000 fuel units (about 50 ms) |
| Linear memory | 64 MiB |
| Message size, either direction | 1 MiB |
| `alas.send` calls per `alas_handle` | 64 |

A trap, a malformed message, or a memory range outside the plugin's memory also
stops the plugin. A stopped plugin can be restarted from Debug → Plugins….

## Example

See `plugins/samples/hello-workspace` for a Rust plugin that uses
`wasm32-unknown-unknown` and `serde_json`.
````

- [ ] **Step 5: Run the manual exit check**

Launch the Debug build next to the regular app:

```bash
open -n "$(xcodebuild -project Alas.xcodeproj -scheme Alas -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d"/"n}')"
```

Then check each item:
1. **Debug → Plugins…** lists **Hello Workspace 0.1.0**, which requests "Read this project's worktrees…". Choose **Approve and run**.
   Expected: each project row shows `active`, with the log lines `activated for "<project>"`, `snapshot: N worktrees, M sessions (K running)`, and `worktree/switch replied {"code":-32001,…}`. Starting an agent session produces a `changed: …` line within about a second.
2. Edit the installed `plugin.json` to `"api": 2`, then choose **Reload**.
   Expected: under "Not loaded" it says `hello-workspace: requires plugin API 2; this Alas supports 1`. Restore `"api": 1` afterwards.
3. Confirm the plugin stayed `active` after the denied `worktree/switch` in item 1.

Tell the user which items passed. Never pkill the Alas binary; quit the Debug instance from its own menu.

- [ ] **Step 6: Commit**

```bash
git add plugins/samples/hello-workspace docs/plugins/api-v1.md
git commit -m "docs(plugins): add API v1 reference and Rust sample plugin"
```
