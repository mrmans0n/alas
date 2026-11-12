# Devices clipboard and text beyond ASCII: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌘V/⌘C on the simulator screen, `device_type` that types any text,
and a `device_clipboard` agent tool.

**Architecture:** AlasCore gets the pure pieces: splitting text into key runs
and paste runs, reading an app's pasteboard permission from the simulator's
`TCC.db`, and simctl `pbcopy`/`pbpaste`/`privacy … pasteboard`. The app gets
`DevicePasteboard`: a per-simulator lock, the paste session (grant, write,
⌘V, restore) and copy (⌘C, poll). `DeviceAgentControl` and the screen's
responder actions use it. The app in front comes from one SpringBoard
tracker per simulator, shared by the Logs tab and the paste.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, Swift Testing, SQLite3 (system),
Rust (`AlasCLI`).

**Spec:** `docs/plans/2026-11-12-devices-clipboard-design.md`

## Global Constraints

- AlasCore must not import AppKit or SwiftUI; anything the app uses from it is `public`.
- Tests use Swift Testing; extend existing suites; no fixed sleeps; poll with `eventually(_:within:_:)` from `AlasTests/Code/LSP/LSPClientTests.swift`.
- Never write to the simulator's `TCC.db`: open it `SQLITE_OPEN_READONLY`, not through `SQLiteDatabase` (it sets WAL mode on open).
- `device_type` text ≤ 4096 bytes (unchanged); `device_clipboard` text ≤ 65536 bytes; your paste ≤ 1 MB (1_000_000 bytes).
- ⌘ chord: Command is HID usage 0xE3, V 0x19, C 0x06; 20 ms between key events.
- Copy polls `pbpaste` every 100 ms for up to 2 s.
- Messages: "The clipboard has no text to paste.", "That text is too long to paste.", "Copied", "Nothing was copied. Select some text first."; the pill clears after 2 s.
- Commit with explicit paths; Conventional Commits; English only.
- After adding app files, run `xcodegen` and commit only the new-file hunks of `Alas.xcodeproj/project.pbxproj`.

## Review Focus

- A takeover or cancel between runs of a mixed `device_type`: the permission and old text must still come back (Task 4 test).
- An app that already allowed pasting: no grant and no reset afterwards, or the user's own Allow is lost (Task 3 parameterized test).
- An app that had denied pasting: it must be denied again afterwards, not reset to "ask" (Task 3 parameterized test).
- A copy started while a paste on the same simulator is still restoring must wait, or it reads the agent's old text (Task 3 lock test).
- No app in front: the paste must still send ⌘V and must not call `privacy` with an empty bundle ID (Task 3 test row).

---

### Task 1: Text runs and `device_clipboard` decoding (AlasCore)

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/DeviceTextInput.swift`
- Modify: `Packages/AlasCore/Sources/AlasAgentKit/Harness/DeviceCommand.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/DeviceTextInputTests.swift`, `Packages/AlasCore/Tests/AlasCoreTests/DeviceCommandTests.swift`

**Interfaces:**
- Produces: `DeviceTextInput.Run` (`.keys([Press])`, `.paste(String)`, `public var characterCount: Int`), `DeviceTextInput.runs(for: String) -> [Run]`; `DeviceCommand.clipboard(udid: String, text: String?)`, tool name `device_clipboard`. `presses(for:)` and `DeviceTextInputError` stay until Task 4, whose `.type` change drops their last caller and deletes them.

- [ ] **Step 1: Write the tests in `DeviceTextInputTests`**

Replace `textBecomesKeyPressesWithShiftWhereNeeded` and add the parameterized test; keep `stopsAtTheFirstCharacterItCannotType` until Task 4. The suite becomes:

```swift
import Testing
import AlasCore

struct DeviceTextInputTests {
    @Test func textBecomesKeyPressesWithShiftWhereNeeded() {
        guard case .keys(let presses) = DeviceTextInput.runs(for: "Hello, World!\n").first else {
            Issue.record("expected one key run")
            return
        }
        #expect(DeviceTextInput.runs(for: "Hello, World!\n").count == 1)
        #expect(presses.filter(\.shift).map(\.usage) == [0x0B, 0x1A, 0x1E]) // H, W, !
        #expect(presses.map(\.usage) == [
            0x0B, 0x08, 0x0F, 0x0F, 0x12, 0x36, 0x2C, // Hello,<space>
            0x1A, 0x12, 0x15, 0x0F, 0x07, 0x1E, 0x28, // World!<return>
        ])
    }

    /// Each run as "k:<typed text>" or "p:<pasted text>".
    private func shape(_ text: String) -> [String] {
        DeviceTextInput.runs(for: text).map { run in
            switch run {
            case .keys(let presses): "k:\(presses.count)"
            case .paste(let text): "p:\(text)"
            }
        }
    }

    @Test(arguments: [
        ("Café au lait\n", ["k:3", "p:é", "k:9"]),
        ("日本 語", ["p:日本 語"]),
        ("é", ["p:é"]),
        ("a ☕️ b", ["k:2", "p:☕️", "k:2"]),
        ("👋\nhi 👋", ["p:👋", "k:4", "p:👋"]),
    ])
    func charactersTheKeyboardLacksArePasted(text: String, runs: [String]) {
        #expect(shape(text) == runs)
    }

    @Test func stopsAtTheFirstCharacterItCannotType() {
        #expect(DeviceTextInput.presses(for: "café") == .failure(DeviceTextInputError(character: "é")))
    }
}
```

Note the last row: the space between "hi" and 👋 is typed, because only a space with untypeable characters on both sides joins a paste run.

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path Packages/AlasCore --filter DeviceTextInputTests`
Expected: compile error, `runs(for:)` doesn't exist.

- [ ] **Step 3: Implement `runs(for:)`**

In `DeviceTextInput.swift`, keep everything and add:

```swift
    /// A stretch of text typed as keys, or pasted because the US layout lacks it.
    public enum Run: Equatable, Sendable {
        case keys([Press])
        case paste(String)

        public var characterCount: Int {
            switch self {
            case .keys(let presses): presses.count
            case .paste(let text): text.count
            }
        }
    }

    /// Splits text into key runs and paste runs. A space joins a paste run
    /// when the characters on both sides of it are pasted.
    public static func runs(for text: String) -> [Run] {
        let characters = Array(text)
        let typeable = characters.map { press(for: $0) != nil }
        var runs: [Run] = []
        var keys: [Press] = []
        var pasted = ""
        func flushKeys() { if !keys.isEmpty { runs.append(.keys(keys)); keys = [] } }
        func flushPaste() { if !pasted.isEmpty { runs.append(.paste(pasted)); pasted = "" } }
        for (index, character) in characters.enumerated() {
            if character == " ", joinsPaste(at: index, characters, typeable) {
                pasted.append(character)
            } else if let press = press(for: character) {
                flushPaste()
                keys.append(press)
            } else {
                flushKeys()
                pasted.append(character)
            }
        }
        flushKeys()
        flushPaste()
        return runs
    }

    private static func joinsPaste(at index: Int, _ characters: [Character], _ typeable: [Bool]) -> Bool {
        let before = characters[..<index].lastIndex { $0 != " " }
        let after = characters[(index + 1)...].firstIndex { $0 != " " }
        guard let before, let after else { return false }
        return !typeable[before] && !typeable[after]
    }
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --package-path Packages/AlasCore --filter DeviceTextInputTests`
Expected: PASS (6 cases).

- [ ] **Step 5: Add `device_clipboard` rows to `DeviceCommandTests`**

In the decoding table, after the `device_logs` rows:

```swift
        ("device_clipboard", #"{"udid":"U"}"#, .clipboard(udid: "U", text: nil)),
        ("device_clipboard", #"{"udid":"U","text":""}"#, .clipboard(udid: "U", text: "")),
        ("device_clipboard", #"{"udid":"U","text":"Café ☕️"}"#, .clipboard(udid: "U", text: "Café ☕️")),
```

In the malformed table:

```swift
        ("device_clipboard", #"{"udid":"U","text":"\#(String(repeating: "a", count: 65537))"}"#),
        ("device_clipboard", #"{"udid":"U","bundle_id":"b"}"#),
```

Run: `swift test --package-path Packages/AlasCore --filter DeviceCommandTests` → compile error.

- [ ] **Step 6: Decode `device_clipboard`**

In `DeviceCommand.swift`:
- add `case clipboard(udid: String, text: String?)` after `logs`;
- `toolName`: `case .clipboard: "device_clipboard"`;
- `udid`: include `.clipboard(let udid, _)` with the others that return their udid (follow the existing pattern in `public var udid`);
- allowed keys: `"device_clipboard": ["udid", "text"],`;
- decoding, after `device_logs`:

```swift
        case "device_clipboard":
            if let text = params.text, text.utf8.count > 65536 { throw AlasCLIRequestError.malformed }
            return .clipboard(udid: try udid(), text: params.text)
```

- [ ] **Step 7: Run AlasCore tests for both suites**

Run: `swift test --package-path Packages/AlasCore --filter 'DeviceTextInputTests|DeviceCommandTests'`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Packages/AlasCore/Sources/AlasFeatures/Devices/DeviceTextInput.swift Packages/AlasCore/Sources/AlasAgentKit/Harness/DeviceCommand.swift Packages/AlasCore/Tests/AlasCoreTests/DeviceTextInputTests.swift Packages/AlasCore/Tests/AlasCoreTests/DeviceCommandTests.swift
git commit -m "feat(devices): split typed text into key and paste runs"
```

### Task 2: The simulator pasteboard and its permission (AlasCore)

**Files:**
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorPasteboard.swift`
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorControl.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/SimulatorSettingsTests.swift` (extend; it's the suite for simctl-backed simulator state)

**Interfaces:**
- Produces:
  - `public enum SimulatorPasteAccess: Equatable, Sendable { case notSet, allowed, denied }` with `static func read(database: URL, bundleID: String) -> SimulatorPasteAccess` and `var restore: SimulatorPrivacyAction?` (`.notSet → .reset`, `.denied → .revoke`, `.allowed → nil`).
  - `public protocol SimulatorPasteboardControl: Sendable { func read(udid: String) async throws -> String; func write(udid: String, text: String) async throws; func access(udid: String, bundleID: String) async -> SimulatorPasteAccess; func setAccess(udid: String, bundleID: String, _ action: SimulatorPrivacyAction) async throws }`
  - `public struct LiveSimulatorPasteboard: SimulatorPasteboardControl` (`public init()`).
  - `SimulatorControl.pbcopy(udid:text:)`, `pbpaste(udid:) -> String`, `pasteboardPrivacy(udid:action:bundleID:)`, `tccDatabase(udid:) -> URL`.

- [ ] **Step 1: Write the failing test**

Append to `SimulatorSettingsTests.swift`:

```swift
struct SimulatorPasteAccessTests {
    @Test func readsTheAppsPasteboardRowFromTCC() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tcc-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE access (service TEXT, client TEXT, auth_value INTEGER);
            INSERT INTO access VALUES ('kTCCServicePasteboard', 'com.example.allowed', 2);
            INSERT INTO access VALUES ('kTCCServicePasteboard', 'com.example.denied', 0);
            INSERT INTO access VALUES ('kTCCServicePasteboard', 'com.example.asks', 1);
            INSERT INTO access VALUES ('kTCCServiceCamera', 'com.example.camera', 2);
            """, nil, nil, nil)
        sqlite3_close(db)

        #expect(SimulatorPasteAccess.read(database: url, bundleID: "com.example.allowed") == .allowed)
        #expect(SimulatorPasteAccess.read(database: url, bundleID: "com.example.denied") == .denied)
        #expect(SimulatorPasteAccess.read(database: url, bundleID: "com.example.asks") == .notSet)
        #expect(SimulatorPasteAccess.read(database: url, bundleID: "com.example.camera") == .notSet)
        #expect(SimulatorPasteAccess.read(database: url.appendingPathExtension("missing"), bundleID: "x") == .notSet)
    }
}
```

Add `import SQLite3` and `import Foundation` at the top of the file if missing.

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path Packages/AlasCore --filter SimulatorPasteAccessTests`
Expected: compile error, `SimulatorPasteAccess` doesn't exist.

- [ ] **Step 3: Implement `SimulatorPasteboard.swift`**

```swift
import Foundation
import SQLite3

/// An app's "Paste from Other Apps" permission on a simulator, from its
/// `TCC.db`. Pasting with ⌘V sent as HID keys needs it: iOS doesn't count the
/// simulator's key events as a user paste.
public enum SimulatorPasteAccess: Equatable, Sendable {
    case notSet, allowed, denied

    /// Read-only: the simulator's tccd owns the database. Anything unreadable,
    /// and any value but allowed (2) or denied (0), counts as not set.
    public static func read(database: URL, bundleID: String) -> SimulatorPasteAccess {
        guard FileManager.default.fileExists(atPath: database.path) else { return .notSet }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return .notSet
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        let sql = "SELECT auth_value FROM access WHERE service = 'kTCCServicePasteboard' AND client = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return .notSet }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, bundleID, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return .notSet }
        switch sqlite3_column_int(statement, 0) {
        case 2: return .allowed
        case 0: return .denied
        default: return .notSet
        }
    }

    /// What puts this state back after a grant; nil when the grant changed nothing.
    public var restore: SimulatorPrivacyAction? {
        switch self {
        case .notSet: .reset
        case .denied: .revoke
        case .allowed: nil
        }
    }
}

public protocol SimulatorPasteboardControl: Sendable {
    func read(udid: String) async throws -> String
    func write(udid: String, text: String) async throws
    func access(udid: String, bundleID: String) async -> SimulatorPasteAccess
    func setAccess(udid: String, bundleID: String, _ action: SimulatorPrivacyAction) async throws
}

public struct LiveSimulatorPasteboard: SimulatorPasteboardControl {
    public init() {}

    public func read(udid: String) async throws -> String { try await SimulatorControl.pbpaste(udid: udid) }

    public func write(udid: String, text: String) async throws { try await SimulatorControl.pbcopy(udid: udid, text: text) }

    public func access(udid: String, bundleID: String) async -> SimulatorPasteAccess {
        SimulatorPasteAccess.read(database: SimulatorControl.tccDatabase(udid: udid), bundleID: bundleID)
    }

    public func setAccess(udid: String, bundleID: String, _ action: SimulatorPrivacyAction) async throws {
        try await SimulatorControl.pasteboardPrivacy(udid: udid, action: action, bundleID: bundleID)
    }
}
```

In `SimulatorControl.swift`, next to `privacy(...)`:

```swift
    public static func pbcopy(udid: String, text: String) async throws {
        let result = try await Process.run(xcrun, args: ["simctl", "pbcopy", udid], stdin: text)
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
    }

    public static func pbpaste(udid: String) async throws -> String {
        let result = try await Process.run(xcrun, args: ["simctl", "pbpaste", udid])
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
        return result.stdout
    }

    /// `simctl privacy` takes `pasteboard` though its help doesn't list it, so
    /// it isn't a `SimulatorPrivacyService` the user picks from.
    public static func pasteboardPrivacy(udid: String, action: SimulatorPrivacyAction, bundleID: String) async throws {
        let result = try await Process.run(xcrun, args: ["simctl", "privacy", udid, action.rawValue, "pasteboard", bundleID])
        guard result.exitCode == 0 else { throw SimulatorControlError(result) }
    }

    public static func tccDatabase(udid: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(udid)/data/Library/TCC/TCC.db")
    }
```

Check `result.stdout`'s name against `ProcessResult` (it's what `logShow` uses).

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --package-path Packages/AlasCore --filter SimulatorPasteAccessTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorPasteboard.swift Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorControl.swift Packages/AlasCore/Tests/AlasCoreTests/SimulatorSettingsTests.swift
git commit -m "feat(devices): read and write a simulator's pasteboard"
```

### Task 3: Shared foreground tracker and `DevicePasteboard` (app)

**Files:**
- Create: `Alas/Sources/Devices/SimulatorForegroundTracker.swift`
- Create: `Alas/Sources/Devices/DevicePasteboard.swift`
- Modify: `Alas/Sources/Devices/SimulatorLogStream.swift` (an `onAppend` callback)
- Modify: `Alas/Sources/Devices/SimulatorLogsTabView.swift` (use the shared tracker)
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorLog.swift` (`LiveSimulatorLogs` takes the tracker's answer)
- Modify: `Alas/Sources/App/AppState.swift`
- Test: `AlasTests/DevicePasteboardTests.swift` (new: `DevicePasteboard` is a new type)

**Interfaces:**
- Consumes: Task 2's `SimulatorPasteboardControl`, `SimulatorPasteAccess`.
- Produces:
  - `@MainActor final class SimulatorForegroundTracker` with `init(udid: String, fallback: @escaping (String) async -> String?)`, `var isRunning: Bool`, `func start()`, `func bundleID() async -> String?` (waits for the archive read the first time).
  - `AppState.foregroundApp(udid: String) async -> String?` and `AppState.foregroundTracker(udid: String) -> SimulatorForegroundTracker` (one per simulator, restarted when its stream ended).
  - `@MainActor final class DevicePasteboard` with `init(input: any DeviceInput, pasteboard: any SimulatorPasteboardControl, frontmostApp: @escaping (String) async -> String?, sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) })`, `struct Paste`, `func open(udid: String, keepText: Bool) async throws -> Paste`, `func paste(_ text: String, in: Paste) async throws`, `func close(_ paste: Paste) async`, `func copy(udid: String) async throws -> String?`, `func read(udid: String) async throws -> String`, `func write(udid: String, text: String) async throws`.
  - `AppState.devicePasteboard: DevicePasteboard`.

- [ ] **Step 1: Write the failing tests**

`AlasTests/DevicePasteboardTests.swift`:

```swift
import AlasCore
import Foundation
import Testing
@testable import Alas

@MainActor
struct DevicePasteboardTests {
    /// Records each call, and the keys sent so far, in one ordered log.
    final class FakePasteboard: SimulatorPasteboardControl, @unchecked Sendable {
        var text = "old"
        var accessBefore = SimulatorPasteAccess.notSet
        var log: [String] = []
        var onRead: () -> Void = {}
        func read(udid: String) async throws -> String { onRead(); log.append("read"); return text }
        func write(udid: String, text: String) async throws { log.append("write \(text)"); self.text = text }
        func access(udid: String, bundleID: String) async -> SimulatorPasteAccess { accessBefore }
        func setAccess(udid: String, bundleID: String, _ action: SimulatorPrivacyAction) async throws {
            log.append("\(action.rawValue) \(bundleID)")
        }
    }

    private func pasteboard(
        _ fake: FakePasteboard, input: DeviceAgentControlTests.FakeInput = .init(), front: String? = "com.example.app",
        sleep: @escaping @MainActor (Duration) async -> Void = { _ in }
    ) -> DevicePasteboard {
        DevicePasteboard(input: input, pasteboard: fake, frontmostApp: { _ in front }, sleep: sleep)
    }

    @Test(arguments: [
        (SimulatorPasteAccess.notSet, true, ["grant com.example.app", "write é", "write old", "reset com.example.app"]),
        (.allowed, true, ["write é", "write old"]),
        (.denied, true, ["grant com.example.app", "write é", "write old", "revoke com.example.app"]),
        (.notSet, false, ["grant com.example.app", "write é", "reset com.example.app"]),
    ])
    func aPastePutsThePermissionAndTextBack(before: SimulatorPasteAccess, restoreText: Bool, calls: [String]) async throws {
        let fake = FakePasteboard()
        fake.accessBefore = before
        let input = DeviceAgentControlTests.FakeInput()
        let pasteboard = pasteboard(fake, input: input)
        let paste = try await pasteboard.open(udid: "on", keepText: restoreText)
        try await pasteboard.paste("é", in: paste)
        await pasteboard.close(paste)
        #expect(fake.log.filter { $0 != "read" } == calls)
        #expect(input.keys.map(\.usage) == [0xE3, 0x19, 0x19, 0xE3])
    }

    @Test func withNoAppInFrontItPastesWithoutAGrant() async throws {
        let fake = FakePasteboard()
        let input = DeviceAgentControlTests.FakeInput()
        let pasteboard = pasteboard(fake, input: input, front: nil)
        let paste = try await pasteboard.open(udid: "on", keepText: false)
        try await pasteboard.paste("é", in: paste)
        await pasteboard.close(paste)
        #expect(fake.log == ["write é"])
        #expect(input.keys.count == 4)
    }

    @Test func copyReturnsTheNewTextOrNilWhenNothingChanges() async throws {
        let fake = FakePasteboard()
        let pasteboard = pasteboard(fake)
        #expect(try await pasteboard.copy(udid: "on") == nil)
        var reads = 0
        fake.onRead = { reads += 1; if reads == 3 { fake.text = "selected" } }
        #expect(try await pasteboard.copy(udid: "on") == "selected")
    }

    @Test func aCopyWaitsForAPasteOnTheSameSimulator() async throws {
        let fake = FakePasteboard()
        let pasteboard = pasteboard(fake)
        let paste = try await pasteboard.open(udid: "on", keepText: true)
        let copy = Task { try await pasteboard.copy(udid: "on") }
        for _ in 0..<20 { await Task.yield() }
        #expect(fake.log == ["read", "grant com.example.app"])
        try await pasteboard.paste("é", in: paste)
        await pasteboard.close(paste)
        _ = try await copy.value
        #expect(fake.log.prefix(5) == ["read", "grant com.example.app", "write é", "write old", "reset com.example.app"])
    }
}
```

`DeviceAgentControlTests.FakeInput` is already `final class FakeInput` inside the suite; if it is not visible from another suite, change its declaration to `final class FakeInput` without `private` (it isn't private today).

- [ ] **Step 2: Run them to verify they fail**

Add the new test file to the project: `xcodegen`, keeping only the new-file hunks of the pbxproj (`git diff -U0 Alas.xcodeproj/project.pbxproj`, keep hunks mentioning the new file, `git checkout` the pbxproj, `git apply --unidiff-zero` the kept hunks).
Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/DevicePasteboardTests test`
Expected: compile error, `DevicePasteboard` doesn't exist.

- [ ] **Step 3: Implement `DevicePasteboard.swift`**

```swift
import AlasCore
import Foundation
import os

/// Pastes and copies on a simulator, one at a time per simulator. A paste
/// lets the app in front read the pasteboard (⌘V from HID keys needs that),
/// and puts the app's permission, and for agents the old text, back after.
@MainActor
final class DevicePasteboard {
    struct Paste {
        let udid: String
        /// The app granted access, and what it had before; nil with no app in front.
        let app: (bundleID: String, before: SimulatorPasteAccess)?
        /// The text to put back; nil when the pasted text stays.
        let oldText: String?
    }

    private static let log = Logger(subsystem: "io.nlopez.alas", category: "DevicePasteboard")
    private let input: any DeviceInput
    private let pasteboard: any SimulatorPasteboardControl
    private let frontmostApp: (String) async -> String?
    private let sleep: @MainActor (Duration) async -> Void
    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(
        input: any DeviceInput, pasteboard: any SimulatorPasteboardControl,
        frontmostApp: @escaping (String) async -> String?,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.input = input
        self.pasteboard = pasteboard
        self.frontmostApp = frontmostApp
        self.sleep = sleep
    }

    /// Takes the simulator's pasteboard; `close` gives it back. `keepText`
    /// reads the old text so `close` restores it.
    func open(udid: String, keepText: Bool) async throws -> Paste {
        await lock(udid)
        do {
            let oldText = keepText ? try await pasteboard.read(udid: udid) : nil
            var app: (String, SimulatorPasteAccess)?
            if let bundleID = await frontmostApp(udid) {
                let before = await pasteboard.access(udid: udid, bundleID: bundleID)
                if before != .allowed { try await pasteboard.setAccess(udid: udid, bundleID: bundleID, .grant) }
                app = (bundleID, before)
            }
            return Paste(udid: udid, app: app, oldText: oldText?.isEmpty == false ? oldText : nil)
        } catch {
            unlock(udid)
            throw error
        }
    }

    func paste(_ text: String, in paste: Paste) async throws {
        try await pasteboard.write(udid: paste.udid, text: text)
        await chord(udid: paste.udid, usage: 0x19)
    }

    /// Restores what `open` changed, then gives the pasteboard back. A failed
    /// restore is logged: the text did get pasted.
    func close(_ paste: Paste) async {
        if let oldText = paste.oldText {
            do { try await pasteboard.write(udid: paste.udid, text: oldText) } catch {
                Self.log.error("Couldn't restore the pasteboard: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let app = paste.app, let restore = app.before.restore {
            do { try await pasteboard.setAccess(udid: paste.udid, bundleID: app.bundleID, restore) } catch {
                Self.log.error("Couldn't restore \(app.bundleID, privacy: .public)'s paste permission: \(error.localizedDescription, privacy: .public)")
            }
        }
        unlock(paste.udid)
    }

    /// Sends ⌘C and returns what the app copied, or nil when the pasteboard
    /// didn't change within 2 s.
    func copy(udid: String) async throws -> String? {
        await lock(udid)
        defer { unlock(udid) }
        let before = try await pasteboard.read(udid: udid)
        await chord(udid: udid, usage: 0x06)
        for _ in 0..<20 {
            await sleep(.milliseconds(100))
            let now = try await pasteboard.read(udid: udid)
            if now != before { return now }
        }
        return nil
    }

    func read(udid: String) async throws -> String { try await pasteboard.read(udid: udid) }

    func write(udid: String, text: String) async throws {
        await lock(udid)
        defer { unlock(udid) }
        try await pasteboard.write(udid: udid, text: text)
    }

    private func chord(udid: String, usage: UInt32) async {
        let command: UInt32 = 0xE3
        input.key(udid: udid, usage: command, down: true)
        await sleep(.milliseconds(20))
        input.key(udid: udid, usage: usage, down: true)
        await sleep(.milliseconds(20))
        input.key(udid: udid, usage: usage, down: false)
        await sleep(.milliseconds(20))
        input.key(udid: udid, usage: command, down: false)
        await sleep(.milliseconds(20))
    }

    private func lock(_ udid: String) async {
        if busy.insert(udid).inserted { return }
        await withCheckedContinuation { waiters[udid, default: []].append($0) }
    }

    private func unlock(_ udid: String) {
        if var queue = waiters[udid], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[udid] = queue
            next.resume()
        } else {
            busy.remove(udid)
        }
    }
}
```

The lock hands the simulator straight to the next waiter, so `busy` stays set while ownership passes.

- [ ] **Step 4: Implement `SimulatorForegroundTracker.swift`**

Add to `SimulatorLogStream`: `@ObservationIgnored var onAppend: (([SimulatorLogLine]) -> Void)?`, called at the end of `append(_:)` with the new lines.

```swift
import AlasCore
import Foundation
import Observation

/// Which app is in front on one simulator, from SpringBoard's log: the last
/// 10 minutes once, then a live `log stream`. Shared by the Logs tab and
/// pasting, so only the first question waits for the archive.
@MainActor
@Observable
final class SimulatorForegroundTracker {
    private(set) var current: String?
    private(set) var isReady = false

    @ObservationIgnored private let udid: String
    @ObservationIgnored private let fallback: (String) async -> String?
    @ObservationIgnored private let stream = SimulatorLogStream()
    @ObservationIgnored private var state = SimulatorForeground()
    /// Streamed lines that arrived while the archive was read.
    @ObservationIgnored private var early: [SimulatorLogLine] = []
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    var isRunning: Bool { stream.isRunning }

    init(udid: String, fallback: @escaping (String) async -> String?) {
        self.udid = udid
        self.fallback = fallback
    }

    func start() {
        isReady = false
        early = []
        stream.onAppend = { [weak self] lines in self?.received(lines) }
        stream.start(udid: udid, predicate: SimulatorForeground.predicate, levelArguments: [])
        Task {
            if let fromLog = await SimulatorControl.foregroundFromLog(udid: udid) {
                state = fromLog
                current = state.bundleID
            } else {
                state = SimulatorForeground()
                current = await fallback(udid)
            }
            isReady = true
            received(early)
            early = []
            readyWaiters.forEach { $0.resume() }
            readyWaiters = []
        }
    }

    func stop() { stream.stop() }

    func bundleID() async -> String? {
        if !isReady { await withCheckedContinuation { readyWaiters.append($0) } }
        return current
    }

    private func received(_ lines: [SimulatorLogLine]) {
        guard isReady else {
            early += lines
            return
        }
        let before = state.bundleID
        for line in lines { state.apply(message: line.message) }
        if state.bundleID != before { current = state.bundleID }
    }
}
```

`current` only changes from the streamed lines when SpringBoard's own state changed, so a fallback answer survives until SpringBoard reports a change.

- [ ] **Step 5: Share it through `AppState` and use it for logs**

In `LiveSimulatorLogs` (`SimulatorLog.swift`): `frontmostApp(udid:)` becomes `await frontmost(udid)`; delete `reportedFrontmostApp(udid:)` and its archive call; update the init's doc comment: "`frontmostApp` answers which app is in front (the app's SpringBoard tracker)." Keep `SimulatorControl.foregroundFromLog`.

In `AppState.swift`, next to `deviceControl`:

```swift
    @ObservationIgnored private var foregroundTrackers: [String: SimulatorForegroundTracker] = [:]

    /// The simulator's SpringBoard tracker, started on first use and again when its stream ended.
    func foregroundTracker(udid: String) -> SimulatorForegroundTracker {
        if let tracker = foregroundTrackers[udid], tracker.isRunning { return tracker }
        let tracker = SimulatorForegroundTracker(udid: udid) { [simulatorStreams] udid in
            let reported = await simulatorStreams.frontmostApp(udid: udid)
            // The bridge names SpringBoard when the home screen is in front.
            return reported == "com.apple.springboard" ? nil : reported
        }
        foregroundTrackers[udid] = tracker
        tracker.start()
        return tracker
    }

    func foregroundApp(udid: String) async -> String? {
        await foregroundTracker(udid: udid).bundleID()
    }

    @ObservationIgnored lazy var devicePasteboard = DevicePasteboard(
        input: simulatorStreams, pasteboard: LiveSimulatorPasteboard(),
        frontmostApp: { [weak self] udid in await self?.foregroundApp(udid: udid) }
    )
```

and `deviceControl`'s `logs:` becomes `LiveSimulatorLogs { [weak self] udid in await self?.foregroundApp(udid: udid) }`.

In `SimulatorLogsTabView`, delete `springboard`, `foreground`, `springboardApplied`, `springboardReady`, `applySpringboard()`, the `.onChange(of: springboard...)` and `springboard.stop()`, and the `logs` helper. The `.foreground` case of `followForeground()` becomes:

```swift
        case .foreground:
            following = ""
            let tracker = state.foregroundTracker(udid: udid)
            await show(await tracker.bundleID())
```

and add, next to the other `.onChange` modifiers:

```swift
        .onChange(of: state.foregroundTracker(udid: udid).current) { _, front in
            guard source == .foreground else { return }
            Task { await show(front) }
        }
```

- [ ] **Step 6: Run the tests**

`xcodegen` (new-file hunks only, as in Step 2), then:
Run: `xcodebuild … -only-testing AlasTests/DevicePasteboardTests test`
Expected: PASS, 7 test cases. Check the "Test run with N tests" line.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Devices/SimulatorForegroundTracker.swift Alas/Sources/Devices/DevicePasteboard.swift Alas/Sources/Devices/SimulatorLogStream.swift Alas/Sources/Devices/SimulatorLogsTabView.swift Alas/Sources/App/AppState.swift Packages/AlasCore/Sources/AlasFeatures/Devices/SimulatorLog.swift AlasTests/DevicePasteboardTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(devices): paste and copy on a simulator, one at a time"
```

### Task 4: Agents: `device_type` pastes, `device_clipboard`

**Files:**
- Modify: `Alas/Sources/Devices/DeviceAgentControl.swift`
- Modify: `Alas/Sources/App/AppState.swift`, `Alas/Sources/App/DesignCaptureDevices.swift` (pass `pasteboard:`)
- Modify: `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift`
- Modify: `AlasCLI/crates/alas-client/src/lib.rs`, `AlasCLI/crates/alas/src/mcp.rs`
- Test: `AlasTests/DeviceAgentControlTests.swift`, `AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift`

**Interfaces:**
- Consumes: Task 1's `DeviceTextInput.runs(for:)`, `.clipboard`; Task 3's `DevicePasteboard`.
- Produces: `DeviceAgentControl.init(…, logs:, pasteboard: DevicePasteboard, now:, sleep:)`.

- [ ] **Step 1: Write the failing tests**

In `DeviceAgentControlTests`, give `control(...)` a `pasteboard: DevicePasteboardTests.FakePasteboard = .init()` parameter and pass `pasteboard: DevicePasteboard(input: input, pasteboard: pasteboard, frontmostApp: { _ in "com.example.app" }, sleep: sleep)` to `DeviceAgentControl`. Update the other direct `DeviceAgentControl(...)` calls in the file the same way. Then add:

```swift
    @Test func typingPastesWhatTheKeyboardLacksAndPutsThePasteboardBackOnce() async throws {
        let input = FakeInput()
        let pasteboard = DevicePasteboardTests.FakePasteboard()
        let control = control(input, pasteboard: pasteboard)
        let response = await control.perform(.type(udid: "on", text: "a é b ☕️\n", includeScreenshot: false), sessionID: "s")
        #expect(error(response) == nil)
        let downs = input.keys.filter(\.down).map(\.usage)
        // a, space, ⌘V, space, b, space, ⌘V, Return
        #expect(downs == [0x04, 0x2C, 0xE3, 0x19, 0x2C, 0x05, 0x2C, 0xE3, 0x19, 0x28])
        #expect(pasteboard.log == ["read", "grant com.example.app", "write é", "write ☕️", "write old", "reset com.example.app"])
    }

    @Test func aTakeoverWhileTypingStillPutsThePasteboardBack() async throws {
        let input = FakeInput()
        let pasteboard = DevicePasteboardTests.FakePasteboard()
        let control = control(input, pasteboard: pasteboard)
        pasteboard.onRead = { control.takeOver(udid: "on") }
        let response = await control.perform(.type(udid: "on", text: "é then more", includeScreenshot: false), sessionID: "s")
        #expect(error(response)?.hasPrefix("device_user_active") == true)
        #expect(pasteboard.log.suffix(2) == ["write old", "reset com.example.app"])
    }

    @Test func clipboardReadsAreNotHeldDuringATakeoverButWritesAre() async throws {
        let pasteboard = DevicePasteboardTests.FakePasteboard()
        let control = control(FakeInput(), pasteboard: pasteboard, sleep: Self.untilCancelled)
        control.takeOver(udid: "on")
        let read = await control.perform(.clipboard(udid: "on", text: nil), sessionID: "s")
        #expect(read == .text([#"{"text":"old"}"#]))
        async let write = control.perform(.clipboard(udid: "on", text: "new"), sessionID: "s")
        try await eventually("write is held") { control.waitingSessions(udid: "on") == ["s"] }
        control.handBack(udid: "on")
        #expect(await write == .text([#"{"ok":true}"#]))
        #expect(pasteboard.text == "new")
    }
```

`error(_:)` is the suite's existing helper; `AlasCLIResponse` compares with `==` (if it isn't `Equatable`, match `case .text(let text)` as `logsJSON` does). `Self.json` sorts keys. Delete any existing test that expects `device_type_unsupported`.

Also delete `DeviceTextInputError`, `presses(for:)` and the `stopsAtTheFirstCharacterItCannotType` test in AlasCore: after Step 3 nothing calls them (run `swift test --package-path Packages/AlasCore --filter DeviceTextInputTests` again in Step 6).

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild … -only-testing AlasTests/DeviceAgentControlTests test`
Expected: compile error (`pasteboard:` doesn't exist; `presses(for:)` is gone).

- [ ] **Step 3: Implement in `DeviceAgentControl`**

- Stored property `@ObservationIgnored private let pasteboard: DevicePasteboard`, init parameter `pasteboard: DevicePasteboard` after `logs:`.
- Extract the device lookup and booted check at the top of `readLogs` into `private func bootedDevice(_ udid: String) async -> Result<SimulatorDevice, AlasCLIResponse>` and use it in `readLogs` too.
- Right after the `.logs` early branch:

```swift
        if case .clipboard(_, nil) = command {
            switch await bootedDevice(udid) {
            case .failure(let response): return response
            case .success:
                do { return .text([Self.json(["text": try await pasteboard.read(udid: udid)])]) } catch {
                    return .error("device_clipboard_failed: \(error.localizedDescription)")
                }
            }
        }
```

- `isInput`: add `.clipboard` to the `true` list (only writes get there).
- Replace the `.type` case:

```swift
        case .type(_, let text, let includeScreenshot):
            let runs = DeviceTextInput.runs(for: text)
            let total = runs.reduce(0) { $0 + $1.characterCount }
            var paste: DevicePasteboard.Paste?
            let stopped = await typeRuns(runs, total: total, udid: udid, paste: &paste)
            if let paste { await pasteboard.close(paste) }
            if let stopped { return stopped }
            return await finish(udid, includeScreenshot: includeScreenshot)
        case .clipboard(_, let text):
            do {
                try await pasteboard.write(udid: udid, text: text ?? "")
                return .text([Self.json(["ok": true])])
            } catch {
                return .error("device_clipboard_failed: \(error.localizedDescription)")
            }
```

and add:

```swift
    /// Types key runs and pastes the rest, opening the paste on the first
    /// paste run. Returns the response that stopped it, or nil when all of it went in.
    private func typeRuns(
        _ runs: [DeviceTextInput.Run], total: Int, udid: String, paste: inout DevicePasteboard.Paste?
    ) async -> AlasCLIResponse? {
        let shift: UInt32 = 0xE1
        var typed = 0
        func stop() -> AlasCLIResponse? {
            if Task.isCancelled {
                return .error("device_cancelled: The call was cancelled after \(typed) of \(total) characters were typed.")
            }
            if userDriving(udid) {
                return .error("device_user_active: The user took over after \(typed) of \(total) characters were typed. Check the field before typing the rest.")
            }
            return nil
        }
        for run in runs {
            switch run {
            case .keys(let presses):
                for press in presses {
                    if let stopped = stop() { return stopped }
                    if press.shift { input.key(udid: udid, usage: shift, down: true) }
                    input.key(udid: udid, usage: press.usage, down: true)
                    input.key(udid: udid, usage: press.usage, down: false)
                    if press.shift { input.key(udid: udid, usage: shift, down: false) }
                    await sleep(.milliseconds(20))
                    typed += 1
                }
            case .paste(let text):
                if let stopped = stop() { return stopped }
                do {
                    if paste == nil { paste = try await pasteboard.open(udid: udid, keepText: true) }
                    if let stopped = stop() { return stopped }
                    try await pasteboard.paste(text, in: paste!)
                } catch {
                    return .error("device_paste_failed: \(error.localizedDescription) \(typed) of \(total) characters were typed.")
                }
                typed += text.count
            }
        }
        return nil
    }
```

- `AppState.deviceControl` and both `DeviceAgentControl(...)` calls in `DesignCaptureDevices.swift` pass `pasteboard:` (`devicePasteboard` in `AppState`; in the design capture, `DevicePasteboard(input: FakeInput(), pasteboard: LiveSimulatorPasteboard(), frontmostApp: { _ in nil })`).

- [ ] **Step 4: Preamble**

In `ACPMCPPromptPreamble.swift`, add `"device_clipboard"` after `"device_logs"` in `builtInToolNames`, and after the `device_logs` sentence add `+ "device_type types any text; read or set the simulator's pasteboard with device_clipboard. "`. Add `device_clipboard` to the inventory in `ACPMCPPromptPreambleTests`.

- [ ] **Step 5: Rust**

`alas-client/src/lib.rs`:
- `DeviceCommand::Clipboard { udid: String, text: Option<String> }` after `Logs`;
- `includes_screenshot`: add `| DeviceCommand::Clipboard { .. }` to the `false` arm;
- `device_request`: 

```rust
        DeviceCommand::Clipboard { udid, text } => {
            let mut params = json!({ "udid": udid });
            if let Some(text) = text {
                params["text"] = json!(text);
            }
            ("device_clipboard", params)
        }
```

- the request test: `build(DeviceCommand::Clipboard { udid: udid(), text: None }).1 == json!({ "udid": "U-1" })`.

`alas/src/mcp.rs`:
- `device_type` description: `format!("Type text into the focused field of the simulator. ASCII is typed as key presses on a US keyboard, and \\n presses Return; other characters, such as accents and emoji, are pasted. Tap the field first. {DEVICE_DRIVING_NOTE}")`;
- after `device_logs`:

```rust
        json!({
            "name": "device_clipboard",
            "description": format!("Read the simulator's pasteboard, or set it by passing text. To paste it into a field, tap the field and type with device_type, or use the app's Paste menu. Setting it waits while the user drives. {DEVICE_DRIVING_NOTE}"),
            "annotations": { "readOnlyHint": false, "destructiveHint": false },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "udid": udid,
                    "text": { "type": "string", "maxLength": 65536, "description": "Omit to read the pasteboard." }
                },
                "required": ["udid"]
            }
        }),
```

- parsing:

```rust
        "device_clipboard" => {
            reject_arguments(args, name, &["udid", "text"])?;
            let text = match args.get("text") {
                None => None,
                Some(Value::String(text)) if text.len() <= 65536 => Some(text.clone()),
                _ => return Err("text must be a string of at most 65536 bytes".into()),
            };
            Ok(Command::Device(alas_client::DeviceCommand::Clipboard {
                udid: required_limited_string(args, "udid", 64)?,
                text,
            }))
        }
```

- tests: a mapping assertion (`map("device_clipboard", json!({ "udid": "U", "text": "é" }))` → `Clipboard { udid: "U", text: Some("é") }`), an error row (`("device_clipboard", json!({ "udid": "U", "text": 1 }), "text must be a string of at most 65536 bytes")`), and `"device_clipboard"` in the tool inventory after `"device_logs"`.

- [ ] **Step 6: Run the checks**

Run: `cargo test --manifest-path AlasCLI/Cargo.toml -p alas -p alas-client`
Run: `xcodebuild … -only-testing AlasTests/DeviceAgentControlTests -only-testing AlasTests/DevicePasteboardTests -only-testing AlasTests/ACPMCPPromptPreambleTests test`
Expected: all pass; check the suite count line.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Devices/DeviceAgentControl.swift Alas/Sources/App/AppState.swift Alas/Sources/App/DesignCaptureDevices.swift Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPMCPPromptPreamble.swift AlasTests/DeviceAgentControlTests.swift AlasTests/ACP/Session/ACPMCPPromptPreambleTests.swift AlasCLI/crates/alas-client/src/lib.rs AlasCLI/crates/alas/src/mcp.rs
git commit -m "feat(devices): let agents type any text and use the simulator's pasteboard"
```

### Task 5: ⌘C and ⌘V on the screen

**Files:**
- Modify: `Alas/Sources/Devices/DeviceScreenView.swift`
- Modify: `Alas/Sources/Devices/DevicePaneModel.swift`
- Modify: `Alas/Sources/Devices/DeviceStage.swift`
- Modify: `Alas/Sources/Devices/DevicesTabView.swift`
- Modify: `Alas/Sources/App/DesignCaptureDevices.swift` (if it constructs `DeviceStage`)

**Interfaces:**
- Consumes: Task 3's `AppState.devicePasteboard`.
- Produces: `DevicePaneModel.notices: [String: String]`, `paste(_ text: String?, udid:, pasteboard:)`, `copy(udid:, pasteboard:)`.

No new tests: the decisions are in `DevicePasteboard` (tested); this is AppKit wiring.

- [ ] **Step 1: The model**

In `DevicePaneModel`:

```swift
    /// A short message on each simulator's screen, after a copy or paste.
    private(set) var notices: [String: String] = [:]
    @ObservationIgnored private var noticeTasks: [String: Task<Void, Never>] = [:]

    func paste(_ text: String?, udid: String, pasteboard: DevicePasteboard) async {
        guard let text, !text.isEmpty else { return show("The clipboard has no text to paste.", udid: udid) }
        guard text.utf8.count <= 1_000_000 else { return show("That text is too long to paste.", udid: udid) }
        do {
            let paste = try await pasteboard.open(udid: udid, keepText: false)
            do { try await pasteboard.paste(text, in: paste) } catch {
                await pasteboard.close(paste)
                return show("Couldn't paste: \(error.localizedDescription)", udid: udid)
            }
            await pasteboard.close(paste)
        } catch {
            show("Couldn't paste: \(error.localizedDescription)", udid: udid)
        }
    }

    func copy(udid: String, pasteboard: DevicePasteboard) async {
        do {
            guard let text = try await pasteboard.copy(udid: udid) else {
                return show("Nothing was copied. Select some text first.", udid: udid)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            show("Copied", udid: udid)
        } catch {
            show("Couldn't copy: \(error.localizedDescription)", udid: udid)
        }
    }

    private func show(_ notice: String, udid: String) {
        notices[udid] = notice
        noticeTasks[udid]?.cancel()
        noticeTasks[udid] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.notices[udid] = nil
        }
    }
```

Add `import AppKit` if the file lacks it.

- [ ] **Step 2: The screen's responder actions**

`DeviceScreenView` gains `var onPaste: () -> Void = {}` and `var onCopy: () -> Void = {}`, set in `makeNSView` and `updateNSView` like `onDropApp`. `DeviceScreenNSView` gains the same two properties and:

```swift
    @objc func paste(_ sender: Any?) { onPaste() }
    @objc func copy(_ sender: Any?) { onCopy() }
```

and

```swift
extension DeviceScreenNSView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(paste(_:)), #selector(copy(_:)): allowsInput && udid != nil
        default: true
        }
    }
}
```

- [ ] **Step 3: The pill and the wiring**

`DeviceStage` gains `let notice: String?`, `let onPaste: () -> Void`, `let onCopy: () -> Void`; passes `onPaste`/`onCopy` to `DeviceScreenView`. In the bottom overlay, show `appInstallPill` when there's an install, else a notice pill when `notice` is set. Move the pill's shared styling (font through stroke overlay) into a private `pill(_:)` helper both use:

```swift
    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6, content: content)
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .background(theme.color("bg-2").opacity(0.6), in: Capsule())
            .overlay(Capsule().strokeBorder(theme.color("line"), lineWidth: 0.5))
            .padding(.horizontal, 12)
    }
```

with the notice pill as `pill { Text(notice).foregroundStyle(theme.color("fg")) }`.

In `DevicesTabView`'s `.booted` case:

```swift
                notice: model.notices[device.udid],
                onPaste: {
                    let text = NSPasteboard.general.string(forType: .string)
                    Task { await model.paste(text, udid: device.udid, pasteboard: state.devicePasteboard) }
                },
                onCopy: { Task { await model.copy(udid: device.udid, pasteboard: state.devicePasteboard) } },
```

Update any other `DeviceStage(...)` call (search with grep) with `notice: nil, onPaste: {}, onCopy: {}`.

- [ ] **Step 4: Build**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -quiet build-for-testing`
Expected: no errors (`build-for-testing` also compiles `DesignCaptureDevices.swift`'s callers the way CI does).

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Devices/DeviceScreenView.swift Alas/Sources/Devices/DevicePaneModel.swift Alas/Sources/Devices/DeviceStage.swift Alas/Sources/Devices/DevicesTabView.swift Alas/Sources/App/DesignCaptureDevices.swift
git commit -m "feat(devices): copy and paste text between the Mac and a simulator"
```

### Task 6: End-to-end check and docs

**Files:**
- Modify: `docs/devices.md`, `docs/plans/2026-11-04-device-panel-design.md`
- Throwaway: `AlasTests/DeviceClipboardScratch.swift` (deleted before committing)

- [ ] **Step 1: Throwaway end-to-end test**

With `/tmp/alas-clip/Field.app` (`com.example.field`, a focused text view that logs `FIELD text=…`; `--copy` starts it with "Hej då ✓ copied" selected) installed on the booted iPhone 17 (`8CA9B1E8-EE67-49E5-846F-293450990F76`), write an app-host test that builds the real `AppState`-style objects (`SimulatorStreamClient`, `LiveSimulatorPasteboard`, a `SimulatorForegroundTracker`, `DevicePasteboard`, `DeviceAgentControl`) and:
1. launches Field, `pbcopy`s "OLD", performs `.type(text: "Café ☕️\n")`, then prints `simctl pbpaste` and the field's last `FIELD text=` line from `log show`, and the `kTCCServicePasteboard` row for `com.example.field` (expect: "Café ☕️" plus a newline in the field, pasteboard "OLD", no row);
2. launches Field with `--copy`, calls `devicePasteboard.copy(udid:)` and prints the result (expect "Hej då ✓ copied").

Run it once with `-only-testing AlasTests/DeviceClipboardScratch`, then delete the file and restore the pbxproj (`git checkout -- Alas.xcodeproj/project.pbxproj`).

- [ ] **Step 2: Docs**

`docs/devices.md`, in "Simulators" after the settings paragraph:

```markdown
⌘C and ⌘V work while the screen has focus. ⌘V pastes the Mac clipboard's
text into the focused field; ⌘C copies the simulator's selection to the Mac
clipboard. iOS only pastes from these keys when the app may paste without
asking, so Alas allows the app in front for the moment of the paste and then
puts its previous setting back. A copy waits up to 2 seconds for the app to
copy something.
```

In the tool table, `device_type` becomes "Types text: ASCII as key presses, `\n` as Return; accents, emoji and other characters are pasted." and add `| device_clipboard | Reads the simulator's pasteboard, or sets it. |` after `device_logs`.

In `docs/plans/2026-11-04-device-panel-design.md`, replace "- [ ] Clipboard both ways (`simctl pbcopy`, `simctl pbpaste`)." with "- [x] Clipboard both ways: ⌘C/⌘V on the screen, `device_clipboard`, and `device_type` pasting text beyond ASCII."

In the spec's section 1 step 2, note that the app in front comes from the shared SpringBoard tracker (`SimulatorForegroundTracker`).

- [ ] **Step 3: Commit**

```bash
git add docs/devices.md docs/plans/2026-11-04-device-panel-design.md docs/plans/2026-11-12-devices-clipboard-design.md
git commit -m "docs(devices): describe the simulator clipboard"
```

- [ ] **Step 4: Manual pass**

Relaunch Alas Dev and ask the user to: copy text on the Mac and ⌘V into a field in Field.app or Safari; select text in the simulator and ⌘C, then paste on the Mac; ask an agent to type "Café ☕️ 日本" into a field; check the Logs tab still follows the app in front.
