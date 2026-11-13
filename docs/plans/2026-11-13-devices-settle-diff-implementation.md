# Devices settle and diff: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Input `device_*` actions wait for the screen to settle and return
what changed since the agent's last snapshot, keeping refs valid.

**Architecture:** AlasCore `DeviceSnapshotDiff` does the pure work: match
elements, carry refs over, build the reply. The app's
`DeviceFrameFingerprint` tells when frames stopped changing;
`DeviceAgentControl` settles, snapshots and diffs after input actions.
`DeviceCommand`'s seven input cases gain `diff: Bool = true`.

**Tech Stack:** Swift 6, Swift Testing, Rust (`AlasCLI`).

**Spec:** `docs/plans/2026-11-13-devices-settle-diff-design.md`

## Global Constraints

- Settle: poll `input.lastFrame` every 50 ms; settled after 6 polls in a row with matching fingerprints (300 ms); give up after 60 polls (3 s). Counting polls, not a clock, keeps tests deterministic with an injected `sleep`.
- Fingerprint: 64×64 grid of bytes from the frame's first plane (luma for `420v`; raw bytes for a non-planar test surface); two match when fewer than 0.5% of samples differ by more than 8.
- Matching key `(role, id, label)`; pairing in snapshot (tree) order — the snapshot's element order is the accessibility tree's, which is screen order for laid-out content. (The spec says top-to-bottom; tree order is what the snapshot has, and is stable.)
- New screen when matched < half of the new elements, or no previous snapshot.
- Lists capped at 200 entries each, with `truncated: true`.
- AlasCore must not import AppKit/SwiftUI; `swiftformat --lint` clean; Swift Testing; no fixed sleeps in tests.
- Commit with explicit paths; xcodegen new-file hunks only.

## Review Focus

- A ref the agent got before the action must still tap the same element after it moved (Task 3 test: carried-over ref taps the new frame).
- Two cells with the same label must not swap refs (Task 1 duplicate-pairing case).
- A blinking caret must not keep a typed field from settling (Task 2 caret-sized-change case).
- The user taking over during settle must not fail the action that already landed (Task 3).
- `diff: false` must leave today's reply byte-for-byte (Task 3).

---

### Task 1: `DeviceSnapshotDiff` (AlasCore)

**Files:**
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/DeviceSnapshotDiff.swift`
- Modify: `Packages/AlasCore/Sources/AlasFeatures/Devices/DeviceSnapshot.swift` (shared element JSON)
- Test: `Packages/AlasCore/Tests/AlasCoreTests/DeviceSnapshotTests.swift` (extend the existing suite file; create a `DeviceSnapshotDiffTests` struct in it)

**Interfaces:**
- Produces:

```swift
public struct DeviceSnapshotDiff: Sendable {
    /// The new snapshot with matched elements carrying their previous refs.
    public let snapshot: DeviceSnapshot
    public let screenChanged: Bool
    public let added: [DeviceElement]
    public let removed: [DeviceElement]
    public let changed: [Change]
    public struct Change: Equatable, Sendable { public let ref: String; public let field: String; public let from: String?; public let to: String? }

    public init(previous: DeviceSnapshot?, next: DeviceSnapshot)
    /// The reply fields: either {screen_changed, screen, elements, truncated?} or {added, removed, changed, truncated?}.
    public func json(limit: Int = 200) -> [String: Any]
}
```

  `DeviceSnapshot` gains `func elementJSON(_ element: DeviceElement) -> [String: Any]` (factored out of `json(query:limit:)`), and an internal memberwise init use.

- [ ] **Step 1: Failing tests** (helper `snap(_ generation: Int, _ elements: [(role, label, value, y)])` building a `DeviceSnapshot` via `DeviceSnapshot.parse` from a small JSON tree, or an internal init exposed with `@testable import AlasCore`):
  - value change: previous `[textfield "Name" value ""]`, next `[textfield "Name" value "Ada"]` → `changed == [.init(ref: "s1e1", field: "value", from: "", to: "Ada")]`, `snapshot.elements[0].ref == "s1e1"`.
  - added/removed: previous `[button A, button B, button C]`, next `[button A, button B, button D]` → added refs `["s2e3"]`, removed refs `["s1e3"]`, not screen changed.
  - scrolled: same elements, every `y` moved by −100 → empty diff, refs kept.
  - duplicates: previous `[cell "Row" y=0, cell "Row" y=50]`, next `[cell "Row" y=-20 enabled false, cell "Row" y=30]` → `changed` has `s1e1 enabled true→false` only.
  - new screen: previous 4 buttons, next 4 different buttons → `screenChanged`, refs all `s2…`; no previous → `screenChanged`.
  - truncation: 250 added → `json()["added"]` has 200 and `truncated == true`.
- [ ] **Step 2: Run** `swift test --package-path Packages/AlasCore --filter DeviceSnapshotDiffTests` → compile error.
- [ ] **Step 3: Implement**

```swift
public init(previous: DeviceSnapshot?, next: DeviceSnapshot) {
    struct Key: Hashable { let role: String; let id: String?; let label: String? }
    func key(_ e: DeviceElement) -> Key { Key(role: e.role, id: e.id, label: e.label) }
    var pool: [Key: [DeviceElement]] = [:]
    for element in previous?.elements ?? [] { pool[key(element), default: []].append(element) }
    var carried: [DeviceElement] = []
    var added: [DeviceElement] = []
    var changed: [Change] = []
    var matched = 0
    for element in next.elements {
        if var candidates = pool[key(element)], !candidates.isEmpty {
            let old = candidates.removeFirst()
            pool[key(element)] = candidates
            matched += 1
            if old.value != element.value { changed.append(Change(ref: old.ref, field: "value", from: old.value, to: element.value)) }
            if old.enabled != element.enabled {
                changed.append(Change(ref: old.ref, field: "enabled", from: String(old.enabled), to: String(element.enabled)))
            }
            carried.append(element.withRef(old.ref))
        } else {
            carried.append(element)
            added.append(element)
        }
    }
    let removed = (previous?.elements ?? []).filter { old in pool[key(old)]?.contains(old) == true }
    screenChanged = previous == nil || matched * 2 < next.elements.count
    snapshot = DeviceSnapshot(generation: next.generation, screenWidth: next.screenWidth,
                              screenHeight: next.screenHeight, elements: screenChanged ? next.elements : carried)
    self.added = screenChanged ? [] : added
    self.removed = screenChanged ? [] : removed
    self.changed = screenChanged ? [] : changed
}
```

  `DeviceElement.withRef(_:)` returns a copy with another ref. Note an empty
  `next` with a previous snapshot: `0 * 2 < 0` is false, so it's a diff where
  everything was removed. `json(limit:)`: screen changed →
  `["screen_changed": true, "screen": [...], "elements": first limit via elementJSON]`;
  otherwise `added` (elementJSON), `removed` (`ref`, `role`, `label`),
  `changed` (`ref`, `field`, `from`, `to`, omitting nil), each prefix(limit),
  and `truncated: true` when any list was cut.
- [ ] **Step 4: Run** → PASS; lint.
- [ ] **Step 5: Commit** "feat(devices): diff simulator snapshots and keep refs of elements still on screen".

### Task 2: `diff` on the input commands, and the frame fingerprint

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasAgentKit/Harness/DeviceCommand.swift`, `DeviceCommandTests.swift`
- Create: `Alas/Sources/Devices/DeviceFrameFingerprint.swift`, `AlasTests/DeviceFrameFingerprintTests.swift`

**Interfaces:**
- `case tap(udid:target:includeScreenshot:diff: Bool = true)`, the same `diff: Bool = true` last on `swipe`, `type`, `button`, `launch`, `openURL`, `rotate`. Allowed keys gain `"diff"` for those tools; decoding `params.diff ?? true` (`Params.diff: Bool?`).
- `struct DeviceFrameFingerprint: Equatable { init?(_ surface: IOSurface); func matches(_ other: Self) -> Bool }`.

- [ ] **Step 1: Failing tests.** `DeviceCommandTests`: `("device_tap", #"{"udid":"U","x":1,"y":2,"diff":false}"#, .tap(udid: "U", target: .point(x: 1, y: 2), includeScreenshot: false, diff: false))`, and a malformed row `("device_snapshot", #"{"udid":"U","diff":false}"#)`. `DeviceFrameFingerprintTests` (parameterized over the changed fraction): a 64×128 BGRA surface filled with 100; a copy with a 2×2 block set to 255 matches (caret); a copy with the top quarter set to 255 doesn't; identical matches.
- [ ] **Step 2: Run** → fail.
- [ ] **Step 3: Implement** the command change (update the patterns in `DeviceAgentControl` to bind the new field with `_` for now so the app still builds), and:

```swift
import IOSurface

/// A coarse sample of a frame's pixels, to tell when the screen stopped changing.
struct DeviceFrameFingerprint: Equatable {
    private let samples: [UInt8]

    init?(_ surface: IOSurface) {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let planar = surface.planeCount > 0
        let base = planar ? surface.baseAddress(ofPlane: 0) : surface.baseAddress
        let rowBytes = planar ? surface.bytesPerRow(ofPlane: 0) : surface.bytesPerRow
        let width = planar ? surface.width(ofPlane: 0) * 1 : surface.bytesPerRow
        let height = planar ? surface.height(ofPlane: 0) : surface.height
        guard width > 0, height > 0 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var samples: [UInt8] = []
        samples.reserveCapacity(64 * 64)
        for row in 0..<64 {
            let y = (row * height) / 64 + height / 128
            for column in 0..<64 {
                let x = (column * width) / 64 + width / 128
                samples.append(bytes[min(y, height - 1) * rowBytes + min(x, rowBytes - 1)])
            }
        }
        self.samples = samples
    }

    /// Fewer than 0.5% of samples differ by more than 8.
    func matches(_ other: Self) -> Bool {
        let differing = zip(samples, other.samples).count { abs(Int($0) - Int($1)) > 8 }
        return differing * 200 < samples.count
    }
}
```

  (Check the `IOSurface` Swift overlay's method names — `baseAddress(ofPlane:)`, `bytesPerRow(ofPlane:)`, `width(ofPlane:)`, `planeCount` — and fix to the actual API if they differ.)
- [ ] **Step 4: Run** AlasCore filter, `-only-testing AlasTests/DeviceFrameFingerprintTests`, xcodegen new-file hunks.
- [ ] **Step 5: Commit** "feat(devices): tell when a simulator's screen stopped changing".

### Task 3: Settle and diff in `DeviceAgentControl`

**Files:**
- Modify: `Alas/Sources/Devices/DeviceAgentControl.swift`, `AlasTests/DeviceAgentControlTests.swift`

- [ ] **Step 1: Failing tests** (`FakeInput` gains `var frames: [IOSurface]` consumed one per `lastFrame` call when non-empty, falling back to `frame`, and `var snapshotSequence: [Data]` consumed per `describe` when non-empty):
  - `aTapReturnsWhatChangedAndRefsKeepWorking`: snapshot (fixture with Maps button and General cell); `describe` next returns the fixture with General moved to y=420 and Maps' label unchanged plus a new Button "Done"; `.tap(ref: "s1e1")` → reply JSON has `settled: true`, `added` with label "Done", `removed` empty. Then `.tap(ref: "s1e2", diff: false)` → the touch lands at the cell's new center (y = (420+26)/874).
  - `withoutDiffTheReplyIsUnchanged`: `.tap(..., diff: false)` → `.ok`.
  - `aSnapshotFailureAfterTheTapStillSucceeds`: `describe` throws on the second call → reply contains `"diff_error"` and the touch was sent.
  - `aScreenThatNeverSettlesIsReportedAsSuch`: `frames` holds 80 alternating surfaces (all-0 and all-255) → reply has `"settled": false`.
- [ ] **Step 2: Run** → fail.
- [ ] **Step 3: Implement.**
  - `private func settle(_ udid: String) async -> Bool`: poll as in Global Constraints with `sleep(.milliseconds(50))`; stop early returning false when `userDriving(udid) || Task.isCancelled`.
  - `private func diffReply(_ udid: String) async -> [String: Any]`: `let settled = await settle(udid)`; if the user drives → `["diff_error": "The user took over."]`; else snapshot through the same code `.snapshot` uses (factor it into `takeSnapshot(_ udid:) async throws -> DeviceSnapshot`), `DeviceSnapshotDiff(previous: snapshots[udid], next:)`, store `diff.snapshot` in `snapshots[udid]` (respecting the generation check), return `diff.json()` plus `"settled": settled`; on error `["settled": settled, "diff_error": message]`.
  - `finish(udid, includeScreenshot:diff:)`: when `diff`, build the reply from `diffReply`, then, if `includeScreenshot`, add the screenshot fields; when not, today's behaviour. `launch`, `openURL`, `rotate` merge `diffReply` into their JSON when `diff`.
- [ ] **Step 4: Run** `DeviceAgentControlTests` → PASS (existing tests that expect `.ok` from actions now pass `diff: false`, or assert on the new reply: update them in this step, deleting assertions that pinned `.ok` only).
- [ ] **Step 5: Commit** "feat(devices): return what changed after agents' simulator actions".

### Task 4: Tools, preamble, docs, end-to-end

**Files:** `AlasCLI/crates/alas-client/src/lib.rs`, `AlasCLI/crates/alas/src/mcp.rs`, `ACPMCPPromptPreamble.swift` (+ test if a sentence is asserted), `docs/devices.md`, `docs/plans/2026-11-04-device-panel-design.md`; throwaway `AlasTests/DeviceSettleScratch.swift`.

- [ ] **Step 1: Rust.** `diff: bool` on `Tap`, `Swipe`, `Type`, `Button`, `Launch`, `OpenUrl`, `Rotate`; requests include `"diff": false` only when false (so today's request shape stays for the default); `optional_bool(args, "diff")?.unwrap_or(true)` in the seven parsers, `"diff"` in their `reject_arguments` lists and schemas (`{ "type": "boolean", "description": "Return what changed on the screen once it settles. Default: true." }`); description sentence from the spec; tests: one mapping with `diff: false`, request shape unchanged by default.
- [ ] **Step 2: Preamble** sentence from the spec, after the `device_snapshot` sentence.
- [ ] **Step 3: Run** cargo, `ACPMCPPromptPreambleTests`, `DeviceAgentControlTests`, build-for-testing, lint. **Commit** "feat(devices): tell agents device actions return what changed".
- [ ] **Step 4: End-to-end** (throwaway, deleted after): Settings on the booted iPhone 17 — `device_snapshot`, tap "General" by ref → print the reply (expect `screen_changed`); go back with a swipe from the left edge or `device_button home` + relaunch; in Safari, tap the address bar and type "abc" → print `changed` (expect the field's value). Report timings of each action.
- [ ] **Step 5: Docs.** `docs/devices.md` after the tool table: "Taps, swipes, typing, buttons, launching, opening URLs and rotating wait for the screen to settle and return what changed since the agent's last look: elements added and removed, and changed values. Refs of elements still on screen keep working." Tick "Settle-and-diff" in the device panel design. **Commit** "docs(devices): describe settle and diff".
