# AlasCore Phase 0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a local SwiftPM package, `Packages/AlasCore`, that holds Alas's dependency-free leaf code and runs its tests with `swift test`, with no app host, Ghostty, MLX, or submodules.

**Architecture:** One SwiftPM library target, `AlasCore`, and one test target, `AlasCoreTests`. The Alas app target depends on it through xcodegen's local `packages:` entry. A single `@_exported import AlasCore` in the app keeps the ~50 files that use the moved types untouched, which avoids merge conflicts with in-flight PRs. The moved files are relocated with `git mv` and only gain `public` access modifiers, so behavior stays the same.

**Tech Stack:** Swift 6 language mode, swift-tools-version 6.0, Swift Testing, xcodegen, GitHub Actions (`macos-26`).

**Spec:** #1915 (umbrella: "Extract a headless Alas core"). This plan implements #1916.

## Global Constraints

- `swift-tools-version: 6.0`, platforms `.macOS(.v15)`. This matches `SWIFT_VERSION: "6.0"`, `MACOSX_DEPLOYMENT_TARGET: "15.0"` and `SWIFT_STRICT_CONCURRENCY: complete` in `project.yml`.
- No behavior change. The diff for each moved file may only add `public`, add `Sendable`, add `public init() {}`, or make the one change listed in Task 3 (inlining `Paths.ensureDirectoryExists`).
- The `Sendable` conformances listed in each task restore what the type had implicitly while it was internal. If one does not compile, the type was not implicitly `Sendable` before either. Drop that conformance, and never use `@unchecked`.
- Tests use Swift Testing (`import Testing`). Moved tests change only their import line.
- After editing `project.yml`, run `xcodegen` and commit both `project.yml` and `Alas.xcodeproj`.
- Conventional Commits. No `Co-Authored-By` trailers or generated-by footers (AGENTS.md).
- This plan lives under the gitignored `docs/superpowers/`, so add it with `git add -f`.

## Phase 0 scope (verified leaves)

These files reference no app type outside this set:

| Folder | Files | Moved tests |
|---|---|---|
| `SQLiteKit/` | `SQLiteDatabase`, `SQLiteStatement`, `SQLiteError` | `SQLiteKit/SQLiteDatabaseTests`, `SQLiteKit/SQLiteErrorTests` |
| `Helpers/` | `BlockingWork`, `LineBuffer`, `SpawnedProcess` | none |
| `JSONRPC/` | `JSONRPCFramer`, `JSONRPCNewlineFramer`, `JSONRPCStdioTransport` | `JSONRPC/JSONRPCFramerTests`, `JSONRPC/JSONRPCFramerBoundsTests` |
| `Watch/` | `DebounceTimer`, `GitEventFilter`, `WorktreeWatcher` | `DebounceTimerTests`, `GitEventFilterTests`, `WorktreeWatcherFilterTests`, `WorktreeWatcherTests` |
| `Persistence/` | `PersistenceStore` only | `PersistenceStoreTests` |

These are explicitly **out of scope**:

- `Watch/ProjectGitWatcher.swift` needs `HeadReader` from Git.
- The rest of `Persistence/`, because `AppConfig` references `Shortcuts`, `Code/Editor`, `Center/Diff` and `Dialogs` types. Splitting it has its own ticket.
- All of `Issues/`, which needs `Integrations/CodeHost` and `ACP/LocalText`.
- `ProjectMCPServer` and `RepoMCPResolver`. Their tests need `ProjectMCPValidation` and `RepoMCPTrust`, which reach into `ACP/Session`.

## Review Focus

1. **Cross-module generic specialization.** `LSPTransport` calls `JSONRPCFramer.append(_:)`, which is generic over `Collection`. Across a module boundary, that call is no longer specialized, and it sits on every LSP read. Task 2 adds a concrete `Data` overload so the app's call specializes inside AlasCore.
2. **Implicit `Sendable` is lost for public value types.** Swift infers `Sendable` only for non-public structs and enums. Under `complete` strict concurrency, the app breaks wherever it sends `JSONRPCFraming`, `JSONRPCProcessTerminationScope`, `GitEventCategory`, `SQLiteError`, `PersistenceReadResult` or `PersistenceStore` across isolation. Each task adds explicit `Sendable` to these types.
3. **Main-actor and main-queue tests with no app host.** Under `swift test`, `WorktreeWatcherTests` has an `@MainActor` test, and `DebounceTimer` defaults to `queue: .main`. They must pass with no NSApplication run loop. Task 3 runs them under `swift test` specifically.
4. **Test doubles in AlasTests that conform to moved protocols.** About 60 `MemoryStore`s conform to `PersistenceStoreProtocol`, and three fakes conform to `JSONRPCStdioTransporting` (`FakeJSONRPCTransport`, `RecordingTransport`, `RemotePathStrippingTransport`). Every protocol requirement, and every default implementation in a protocol extension, must be `public`. Otherwise AlasTests fails to compile even though the app builds. Each task runs `build-for-testing`, not just `build`.
5. **CI selectors for moved suites.** `scripts/ci-swift-test-timings.json` still names the moved suites. Task 4 removes those entries and confirms the planner still accepts the file.

---

### Task 1: Scaffold AlasCore and move SQLiteKit

**Files:**
- Create: `Packages/AlasCore/Package.swift`
- Create: `Alas/Sources/App/AlasCoreExports.swift`
- Move: `Alas/Sources/SQLiteKit/*.swift` → `Packages/AlasCore/Sources/AlasCore/SQLiteKit/`
- Move: `AlasTests/SQLiteKit/*.swift` → `Packages/AlasCore/Tests/AlasCoreTests/SQLiteKit/`
- Modify: `project.yml` (`packages:` and `targets.Alas.dependencies`)
- Regenerate: `Alas.xcodeproj`

**Interfaces:**
- Produces: the module `AlasCore`, with `public final class SQLiteDatabase`, `public final class SQLiteStatement`, and `public enum SQLiteError: Error, LocalizedError, Sendable`. All of their current non-private members become `public` with the same signatures.

- [ ] **Step 1: Create the package manifest**

`Packages/AlasCore/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlasCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AlasCore", targets: ["AlasCore"]),
    ],
    targets: [
        .target(name: "AlasCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "AlasCoreTests", dependencies: ["AlasCore"]),
    ]
)
```

- [ ] **Step 2: Move the sources and tests**

```bash
mkdir -p Packages/AlasCore/Sources/AlasCore Packages/AlasCore/Tests/AlasCoreTests
git mv Alas/Sources/SQLiteKit Packages/AlasCore/Sources/AlasCore/SQLiteKit
git mv AlasTests/SQLiteKit Packages/AlasCore/Tests/AlasCoreTests/SQLiteKit
sed -i '' 's/^@testable import Alas$/@testable import AlasCore/' Packages/AlasCore/Tests/AlasCoreTests/SQLiteKit/*.swift
```

- [ ] **Step 3: Run the package tests**

Run: `swift test --package-path Packages/AlasCore`
Expected: PASS. `@testable` sees internal declarations, so the moved tests pass before any `public` is added. This step proves the package builds and tests on its own.

- [ ] **Step 4: Make the API public**

In `SQLiteDatabase.swift`, prefix `public` on the class, `init(path:busyTimeoutMilliseconds:)`, `observeReplicaChanges`, `removeReplicaChangeObserver`, `exec`, `execChanges`, `query` and `transaction`.

In `SQLiteStatement.swift`, prefix `public` on the class, `init(db:sql:)`, `bind`, `run` and `rows`.

In `SQLiteError.swift`:

```swift
public enum SQLiteError: Error, LocalizedError, Sendable {
```

Also make `errorDescription` `public var errorDescription: String? {`.

- [ ] **Step 5: Wire the package into the app**

`project.yml`: under `packages:`, add:

```yaml
  AlasCore:
    path: Packages/AlasCore
```

Under `targets.Alas.dependencies`, add:

```yaml
      - package: AlasCore
        product: AlasCore
```

`Alas/Sources/App/AlasCoreExports.swift`:

```swift
// Re-exports AlasCore to every file in the app and to `@testable import Alas`
// in AlasTests, so moving code into the package needs no per-file imports.
@_exported import AlasCore
```

Then run `xcodegen`.

- [ ] **Step 6: Build the app and the tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation -quiet build-for-testing \
  > /tmp/alascore-t1.log 2>&1; echo "exit=$?"
```

Expected: `exit=0`. If a member is reported as inaccessible, it was missed in Step 4. Make it `public` and rerun.

Run focused app suites that use SQLite: `-only-testing AlasTests/ACPSessionStoreSchemaTests test`.
Expected: the `✔` lines pass for that suite.

- [ ] **Step 7: Commit**

```bash
git add Packages/AlasCore Alas/Sources/App/AlasCoreExports.swift project.yml Alas.xcodeproj
git commit -m "refactor(core): add AlasCore package with SQLiteKit"
```

### Task 2: Move Helpers and JSONRPC

**Files:**
- Move: `Alas/Sources/Helpers/*.swift` → `Packages/AlasCore/Sources/AlasCore/Helpers/`
- Move: `Alas/Sources/JSONRPC/*.swift` → `Packages/AlasCore/Sources/AlasCore/JSONRPC/`
- Move: `AlasTests/JSONRPC/*.swift` → `Packages/AlasCore/Tests/AlasCoreTests/JSONRPC/`
- Regenerate: `Alas.xcodeproj`

**Interfaces:**
- Consumes: the `AlasCore` package from Task 1.
- Produces, all `public`:
  - `enum BlockingWork`, with `run` (both overloads) and `detach`.
  - `final class LineBuffer` with `public init() {}`, `feed(_: String)`, `feed(_: Data)` and `flush()`.
  - `final class SpawnedProcess` with nested `Termination: Equatable, Sendable` (`status`, `shellStatus`), `pid`, `termination`, `isRunning`, `init(executable:arguments:environment:directory:newProcessGroup:stdin:stdout:stderr:onExit:)` and `terminate()`.
  - `struct JSONRPCFramer: Sendable` with `public init() {}`, `maximumBodyBytes`, `maximumHeaderBytes`, `public private(set) var hasFailed`, generic `append`, the new `append(_ data: Data)`, `drainFrames()` and `encode(_:)`.
  - `struct JSONRPCNewlineFramer: Sendable` with `public init() {}`, `append`, `drainFrames()` and `encode(_:)`.
  - `enum JSONRPCFraming: Sendable`.
  - `enum JSONRPCProcessTerminationScope: Equatable, Sendable`.
  - `protocol JSONRPCStdioTransporting`: every requirement, plus the extension's `requestIDPrefix` and `send(_:onWritten:)` defaults.
  - `final class JSONRPCStdioTransport` with `Incoming`, `incoming`, `init(executable:arguments:environment:framing:replaceEnv:terminationScope:)`, `start()`, `send(_:)` and `terminate()`.

- [ ] **Step 1: Move files and tests**

```bash
git mv Alas/Sources/Helpers Packages/AlasCore/Sources/AlasCore/Helpers
git mv Alas/Sources/JSONRPC Packages/AlasCore/Sources/AlasCore/JSONRPC
git mv AlasTests/JSONRPC Packages/AlasCore/Tests/AlasCoreTests/JSONRPC
sed -i '' 's/^@testable import Alas$/@testable import AlasCore/' Packages/AlasCore/Tests/AlasCoreTests/JSONRPC/*.swift
```

- [ ] **Step 2: Run the package tests**

Run: `swift test --package-path Packages/AlasCore`
Expected: PASS, including `JSONRPCFramerTests` and `JSONRPCFramerBoundsTests`.

- [ ] **Step 3: Make the API public, and keep the framer specialized**

Add `public` to every declaration listed under **Produces**. Add `public init() {}` to `LineBuffer`, `JSONRPCFramer` and `JSONRPCNewlineFramer`. Add the `Sendable` conformances as listed.

In `JSONRPCFramer`, rename the existing generic `append` to `private mutating func appendBytes<C: Collection>(_ bytes: C) where C.Element == UInt8`, keeping its body unchanged. Then add two public entry points above it:

```swift
    public mutating func append<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        appendBytes(bytes)
    }

    /// Concrete entry point for callers in other modules: a generic call is
    /// not specialized across the module boundary, and LSP reads land here.
    public mutating func append(_ data: Data) {
        appendBytes(data)
    }
```

Do not implement the `Data` overload by calling `append`, because overload resolution would pick the `Data` overload again and recurse forever. `LSPTransport.swift:93` passes `Data`, so it resolves to the concrete overload.

- [ ] **Step 4: Regenerate, build, and run the affected app suites**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation -quiet build-for-testing \
  > /tmp/alascore-t2.log 2>&1; echo "exit=$?"
```

Expected: `exit=0`. Then run `-only-testing` for `AlasTests/LSPTransportFramingTests`, `AlasTests/ProcessTransportTerminationTests`, `AlasTests/RemoteHostRegistryTests` and `AlasTests/GGCommandRunningStreamingTests`.
Expected: every `✔` passes and there are no `✘` lines.

- [ ] **Step 5: Commit**

```bash
git add -A Packages/AlasCore Alas AlasTests Alas.xcodeproj
git commit -m "refactor(core): move Helpers and JSONRPC into AlasCore"
```

### Task 3: Move the Watch leaves and PersistenceStore

**Files:**
- Move: `Alas/Sources/Watch/{DebounceTimer,GitEventFilter,WorktreeWatcher}.swift` → `Packages/AlasCore/Sources/AlasCore/Watch/`
- Move: `Alas/Sources/Persistence/PersistenceStore.swift` → `Packages/AlasCore/Sources/AlasCore/Persistence/`
- Move: `AlasTests/{DebounceTimerTests,GitEventFilterTests,WorktreeWatcherFilterTests,WorktreeWatcherTests,PersistenceStoreTests}.swift` → `Packages/AlasCore/Tests/AlasCoreTests/`
- Modify: `PersistenceStore.write(_:to:)`, to remove the `Paths` dependency
- Regenerate: `Alas.xcodeproj`

**Interfaces:**
- Produces, all `public`:
  - `final class DebounceTimer`: `onFire`, `init(interval:queue:maxWait:)`, `poke()`, `cancel()`.
  - `enum GitEventCategory: Equatable, Sendable`.
  - `enum GitEventFilter` with `classify(eventPath:gitDir:worktreeRoot:)`.
  - `@MainActor final class WorktreeWatcher`: `onChange`, `init(path:watchesGitDir:)`, `start()`, `stop()`, `nonisolated static func shouldRefresh(forEventPaths:)`.
  - `protocol PersistenceStoreProtocol`, including all three requirements and the extension default.
  - `struct PersistenceReadResult<Value>: Sendable where Value: Sendable` (conditional), with `value`, `recoveryError` and `init(value:recoveryError:)`.
  - `struct PersistenceStore: PersistenceStoreProtocol, Sendable` with `public init()`, `write`, `read`, `readIfExists` and `readIfExistsReportingRecovery`.

- [ ] **Step 1: Move files and tests**

```bash
mkdir -p Packages/AlasCore/Sources/AlasCore/Watch Packages/AlasCore/Sources/AlasCore/Persistence
for f in DebounceTimer GitEventFilter WorktreeWatcher; do
  git mv Alas/Sources/Watch/$f.swift Packages/AlasCore/Sources/AlasCore/Watch/
done
git mv Alas/Sources/Persistence/PersistenceStore.swift Packages/AlasCore/Sources/AlasCore/Persistence/
for t in DebounceTimerTests GitEventFilterTests WorktreeWatcherFilterTests WorktreeWatcherTests PersistenceStoreTests; do
  git mv AlasTests/$t.swift Packages/AlasCore/Tests/AlasCoreTests/
  sed -i '' 's/^@testable import Alas$/@testable import AlasCore/' Packages/AlasCore/Tests/AlasCoreTests/$t.swift
done
```

- [ ] **Step 2: Remove the `Paths` dependency**

In `PersistenceStore.write(_:to:)`, replace:

```swift
        try Paths.ensureDirectoryExists(url.deletingLastPathComponent())
```

with the body of that helper, as defined at `Alas/Sources/Persistence/Paths.swift:166`:

```swift
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
```

- [ ] **Step 3: Run the package tests, including the main-actor ones**

Run: `swift test --package-path Packages/AlasCore`
Expected: PASS for all moved suites. In particular, `WorktreeWatcherTests.stoppingAStartedWatcherReleasesItsStreamOffMainActor` must pass, since it is `@MainActor` and has no app host. If it hangs, stop and report it. Do not add `.serialized` or a sleep.

- [ ] **Step 4: Make the API public**

Apply the **Produces** list. In particular, protocol extension defaults need `public`, or the ~60 `MemoryStore` doubles in AlasTests stop compiling.

- [ ] **Step 5: Regenerate, build, and run the affected app suites**

Run `xcodegen`, then the same `build-for-testing` command as in Task 2, with the log at `/tmp/alascore-t3.log`.
Expected: `exit=0`.

Then run `-only-testing` for `AlasTests/AttentionStoreTests`, `AlasTests/TabsManagerTests` and `AlasTests/ProjectsManagerHeadUpdatesTests`. These cover `PersistenceStoreProtocol` doubles and `GitEventFilter` through `ProjectGitWatcher`.
Expected: all `✔`.

- [ ] **Step 6: Commit**

```bash
git add -A Packages/AlasCore Alas AlasTests Alas.xcodeproj
git commit -m "refactor(core): move watch leaves and PersistenceStore into AlasCore"
```

### Task 4: Run AlasCore in CI and document it

**Files:**
- Modify: `.github/workflows/build.yml` (the `build-test` job: lint step, new test step)
- Modify: `.github/workflows/test-growth.yml` (`paths`)
- Modify: `scripts/test_growth.py` (count package sources and tests)
- Modify: `scripts/tests/test-growth/test_growth_test.py` (only if it pins the path constants)
- Modify: `scripts/ci-swift-test-timings.json` (drop moved suites)
- Modify: `AGENTS.md` ("Before finishing a change")

- [ ] **Step 1: Add the CI step**

In `build.yml`, change the lint step to:

```yaml
        run: swiftformat Alas AlasTests Packages --lint --reporter github-actions-log
```

Directly after it, add:

```yaml
      - name: Test AlasCore
        # Hostless: no app, Ghostty, MLX, or submodules. Fails fast before
        # the app build starts.
        run: swift test --package-path Packages/AlasCore
```

- [ ] **Step 2: Count package code in the test-growth report**

In `scripts/test_growth.py`, change the two constants to lists and pass them as pathspecs:

```python
TESTS = ["AlasTests", "Packages/AlasCore/Tests"]
APP = ["Alas", "Packages/AlasCore/Sources"]
```

Update `line_delta` and `test_count` to splat the lists into `git` (`"--", *path`). In the report's table labels, replace `` `{TESTS}` `` and `` `{APP}` `` with fixed text: "Test lines" and "App lines". In `test-growth.yml`, add `"Packages/**"` to `paths`.

Run: `python3 -m pytest scripts/tests/test-growth -q` (or the runner that directory already uses).
Expected: PASS. If a test pins the old string constants, update it in the same way.

- [ ] **Step 3: Drop the stale timing entries**

Remove the entries naming `SQLiteDatabaseTests`, `SQLiteErrorTests`, `JSONRPCFramerTests`, `JSONRPCFramerBoundsTests`, `DebounceTimerTests`, `GitEventFilterTests`, `WorktreeWatcherFilterTests`, `WorktreeWatcherTests` and `PersistenceStoreTests` from `scripts/ci-swift-test-timings.json`. Leave `JSONRPCStdioFramingFailureTests`, which still lives in AlasTests.

Where one invocation's `selectors` list mixes moved and unmoved suites, delete only the moved selectors.

Run: `bash scripts/tests/swift-test-inventory/run.sh` and `ruby scripts/tests/ci-workflow/test-build-workflow.rb`.
Expected: both pass.

- [ ] **Step 4: Document the local command**

In `AGENTS.md`, under "Before finishing a change", before the `xcodebuild` focused-test bullet, add:

```markdown
- For changes under `Packages/AlasCore`, run its tests first. They need no
  app build, submodules, or Ghostty:

  ```bash
  swift test --package-path Packages/AlasCore
  ```
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build.yml .github/workflows/test-growth.yml scripts AGENTS.md
git commit -m "ci(core): run AlasCore tests hostless before the app build"
```

## Done when

- `swift test --package-path Packages/AlasCore` passes in a fresh worktree with no submodules initialized.
- The Alas app builds and AlasTests compiles. CI's `build-test` job runs the new step, and every test lane stays green.
- `Alas/Sources/{SQLiteKit,Helpers,JSONRPC}` no longer exist. `Alas/Sources/Watch` contains only `ProjectGitWatcher.swift`.
- Record in #1915 how long `swift test` takes on CI, and how long it takes locally from cold. That is the baseline for Phase 1.
