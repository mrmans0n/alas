# Symbol mentions, phase 2: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Warn on a composer symbol badge when its declaration can no longer be found, and render sent symbol mentions in the transcript as code-token badges with a hover preview of what was sent or the code now.

**Architecture:** A pure `ACPSymbolPresence` check reuses `ACPSymbolReference.resolve` and `SymbolSource.read`, so the badge warns exactly when sending would mark the symbol `not found when sent`. The composer text view runs it after insert, restore, trusted paste, and app or window activation, and flips `ACPSymbolChipCell.isMissing`. In the transcript a SwiftUI `ACPSymbolBadge` replaces the `FileChip` for symbol attachments. Its popover hosts `ACPSymbolHoverCard`, fed by a pure `ACPSymbolSentPreview.make` that decides, from the stored snapshot and a live read, what to show.

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit, Swift Testing.

**Spec:** `docs/plans/2026-10-06-composer-symbol-mentions-design.md`, sections "Badge", "Preview", and "Transcript" (phase 2). Phase 1 is merged (#1821). The cold index speedup is phase 3 and not in this plan.

## Global Constraints

- The badge warns exactly when sending would mark the symbol `not found when sent`: same `SymbolSource.read`, same `ACPSymbolReference.resolve`. A declaration that only moved within its file does not warn.
- Warning wording: `⚠ not found`, a trailing segment on the composer badge.
- Triggers: after a symbol is inserted, after a draft is restored, after a trusted composer paste, when the app becomes active, and when the composer's window becomes key. Not watched while Alas stays in front.
- One file read per distinct path per check, off the main actor. No modification-time cache.
- A result applies by URI to the badges currently in the text; a newer check cancels an older one.
- Transcript badge: same look as the composer badge (kind icon, container in the type color, name in its kind's color, code font, 2 pt accent edge and `N lines` segment when code was included). File and session chips keep `FileChip`. Click opens the editor at the sent range through `ACPSymbolReference.openURL(for:snapshot:)`.
- Transcript hover: delay `ACPImageChipHoverController.hoverDelay` (0.25 s), SwiftUI `.popover`, state local to the badge. The badge's size depends only on the stored snapshot.
- Popover content per case: code sent shows the stored excerpt labeled "Sent" with a "Current" toggle once the symbol is found now ("Current (changed)" when the live hash differs); code not sent shows current code with "Changed since sent" when the hash differs; symbol gone now shows "No longer found" plus the excerpt if any; snapshot with `found == false` shows "Not found when sent"; no snapshot shows current code from the badge's own range.
- `contentHash` is the SHA-256 (hex) of the full declaration, never the capped excerpt; one helper computes it for snapshots and for live code.
- Sent excerpts never enter `ACPSymbolHoverCache`, which holds live reads only.
- Not planned: LSP in the preview, context lines, footer switch, click-to-pin.
- Tests use Swift Testing, follow the `AGENTS.md` testing policy (extend existing suites, no fixed sleeps, one behavior per test), and run focused with `-only-testing`.
- After adding Swift files, run `xcodegen` and commit `Alas.xcodeproj/project.pbxproj` with the sources.
- Conventional Commits; no agent attribution anywhere.

## Review Focus

1. A file that cannot be read (deleted, over 1 MB, remote host offline) must warn, because sending would mark it not found. Pinned in Task 2.
2. Two badges for the same file, or the same symbol twice (once with code), must read the file once. Pinned in Task 2.
3. File mentions, session links, and malformed `alas-symbol://` links in the same draft must be ignored by the check, never flagged. Pinned in Task 2.
4. Restoring a draft with one present and one gone symbol must flag only the gone one. Applying a result by URI to the badges now in the text means a result for a replaced draft cannot flag a badge whose declaration exists. Pinned in Task 3.
5. A sent message from before phase 1 (no snapshot) must show current code and no note. Pinned in Task 4.
6. A snapshot whose excerpt was cut (400-line cap) must show 40 lines plus "N more lines", and must not report "Changed since sent" when the file is unchanged. Pinned in Task 4.

## File structure

| File | Responsibility |
|---|---|
| `Alas/Sources/ACP/Session/ACPSymbolReference.swift` | `contentHash(of:)`, used by snapshots. |
| `Alas/Sources/ACP/Session/ACPSymbolPresence.swift` (new) | Which symbol mentions are gone: pure core plus the worktree read. |
| `Alas/Sources/ACP/UI/ACPSymbolChipCell.swift` | `isMissing`, trailing segments, shared line-count text, shared fills. |
| `Alas/Sources/ACP/UI/ACPComposer.swift` | Recheck and apply on the text view; triggers; coordinator observers. |
| `Alas/Sources/ACP/UI/ACPSymbolHoverPreview.swift` | `Loaded.found` carries `contentHash`; `sentWindow(from:)`; card accessory slot. |
| `Alas/Sources/ACP/UI/ACPSymbolSentPreview.swift` (new) | Pure `ACPSymbolSentPreview.make`; sent hover model and view. |
| `Alas/Sources/ACP/UI/ACPSymbolBadge.swift` (new) | SwiftUI code-token badge with delayed hover popover. |
| `Alas/Sources/ACP/UI/ACPTranscriptMessageRows.swift`, `ACPTranscriptRowContent.swift`, `ACPSubagentRowView.swift` | Use the badge; pass the worktree root down. |
| `AlasTests/ACP/Session/ACPSymbolReferenceTests.swift` | Hash, presence, sent preview, and window tests. |
| `AlasTests/ACP/UI/ACPComposerDraftBridgeTests.swift` | Restore flags a gone symbol badge. |
| `CHANGELOG.md` | One Features line once the PR number exists. |

---

### Task 1: One content-hash helper

**Files:**
- Modify: `Alas/Sources/ACP/Session/ACPSymbolReference.swift:140-144`
- Test: `AlasTests/ACP/Session/ACPSymbolReferenceTests.swift`

**Interfaces:**
- Produces: `static func ACPSymbolReference.contentHash(of declaration: String) -> String`, 64 lowercase hex characters. Tasks 4 and 5 call it on live code.

- [ ] **Step 1: Write the failing test**

Add to `ACPSymbolReferenceTests`, after `attachesSnapshots`:

```swift
    @Test("the content hash helper reproduces the hash stamped on a snapshot")
    func contentHashMatchesSnapshot() throws {
        let restore = target("restore", .method, lines: 3...5)
        let uri = ACPSymbolReference.uri(for: restore)
        let expansion = ACPSymbolReference.expansion(
            of: [.resourceLink(uri: uri, name: "SessionManager.restore()")],
            sources: ["Sources/SessionManager.swift": Self.swiftSource],
            worktreeRoot: URL(fileURLWithPath: "/tmp/wt"), embeddedContext: true)
        let declaration = try #require(ACPSymbolReference.resolve(restore, source: Self.swiftSource).declaration)
        #expect(expansion.snapshots[uri]?.contentHash == ACPSymbolReference.contentHash(of: declaration))
        #expect(ACPSymbolReference.contentHash(of: "abc")
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing 'AlasTests/ACPSymbolReferenceTests/contentHashMatchesSnapshot()' test`
Expected: build error `type 'ACPSymbolReference' has no member 'contentHash'`.

- [ ] **Step 3: Add the helper and use it**

In `ACPSymbolReference.swift`, directly above `static func resolve(_ target: Target, source: String?) -> Resolution {`, add:

```swift
    /// SHA-256 (hex) of a full declaration, as stored in `ACPSymbolSnapshot.contentHash`.
    /// Stamping a snapshot and judging live code against one both use it.
    static func contentHash(of declaration: String) -> String {
        SHA256.hash(data: Data(declaration.utf8)).map { String(format: "%02x", $0) }.joined()
    }
```

Replace the inline hash in `expansion(of:sources:worktreeRoot:embeddedContext:)` (the line starting `contentHash: declaration.map { SHA256.hash...`) with:

```swift
                contentHash: declaration.map(Self.contentHash(of:)) ?? "",
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing AlasTests/ACPSymbolReferenceTests test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/ACP/Session/ACPSymbolReference.swift AlasTests/ACP/Session/ACPSymbolReferenceTests.swift
git commit -m "refactor(acp): share the symbol content hash"
```

---

### Task 2: Presence check

**Files:**
- Create: `Alas/Sources/ACP/Session/ACPSymbolPresence.swift`
- Test: `AlasTests/ACP/Session/ACPSymbolReferenceTests.swift`

**Interfaces:**
- Consumes: `ACPSymbolReference.target(fromURI:)`, `ACPSymbolReference.resolve(_:source:)`, `SymbolSource.read(root:relativePath:)`.
- Produces:
  - `ACPSymbolPresence.missing(among uris: [String], read: (String) async -> String?) async -> Set<String>`
  - `ACPSymbolPresence.missing(among uris: [String], worktreeRoot: URL) async -> Set<String>`
  - Both return the URIs, drawn from `uris`, that are symbol links whose declaration cannot be found. Other URIs are ignored.

- [ ] **Step 1: Write the failing test**

Add to `ACPSymbolReferenceTests`:

```swift
    @Test("a symbol mention is missing when its declaration or file is gone; others are ignored; files are read once")
    func presenceMissing() async {
        let present = ACPSymbolReference.uri(for: target("restore", .method, lines: 3...5))
        let presentWithCode = ACPSymbolReference.uri(for: target("restore", .method, lines: 3...5, code: true))
        let gone = ACPSymbolReference.uri(for: target("close", .method, lines: 3...5))
        let unreadable = ACPSymbolReference.uri(for: ACPSymbolReference.Target(
            path: "Sources/Other.swift", name: "run", kind: .function, container: nil, lineRange: 0...0, includeCode: false))
        var reads: [String] = []
        let missing = await ACPSymbolPresence.missing(
            among: [present, presentWithCode, gone, unreadable, "file:///a.swift", "alas-session://abc", "not a uri"]
        ) { path in
            reads.append(path)
            return path == "Sources/SessionManager.swift" ? Self.swiftSource : nil
        }
        #expect(missing == [gone, unreadable])
        #expect(reads.sorted() == ["Sources/Other.swift", "Sources/SessionManager.swift"])
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `xcodebuild ... -only-testing 'AlasTests/ACPSymbolReferenceTests/presenceMissing()' test` (same flags as Task 1).
Expected: build error `cannot find 'ACPSymbolPresence' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Alas/Sources/ACP/Session/ACPSymbolPresence.swift`:

```swift
import Foundation

/// Which symbol mentions in a draft can no longer be found. A mention counts as
/// missing exactly when sending would mark it `not found when sent`: the same
/// read and the same `ACPSymbolReference.resolve`, so the badge and the send
/// cannot disagree.
enum ACPSymbolPresence {
    /// The URIs among `uris` that are symbol links whose declaration is gone.
    /// Anything else (files, sessions, malformed links) is ignored. `read`
    /// returns a file's text by worktree-relative path, or nil when it cannot
    /// be read; it runs once per distinct path.
    static func missing(among uris: [String], read: (String) async -> String?) async -> Set<String> {
        var targets: [String: ACPSymbolReference.Target] = [:]
        for uri in uris where targets[uri] == nil {
            if let target = ACPSymbolReference.target(fromURI: uri) { targets[uri] = target }
        }
        var sources: [String: String] = [:]
        for path in Set(targets.values.map(\.path)) {
            if let text = await read(path) { sources[path] = text }
        }
        return Set(targets.filter {
            !ACPSymbolReference.resolve($0.value, source: sources[$0.value.path]).found
        }.keys)
    }

    static func missing(among uris: [String], worktreeRoot: URL) async -> Set<String> {
        await missing(among: uris) { await SymbolSource.read(root: worktreeRoot, relativePath: $0) }
    }
}
```

- [ ] **Step 4: Run xcodegen, then the suite**

Run: `xcodegen && xcodebuild ... -only-testing AlasTests/ACPSymbolReferenceTests test`
Expected: all tests pass, including `presenceMissing()`.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/ACP/Session/ACPSymbolPresence.swift Alas.xcodeproj/project.pbxproj AlasTests/ACP/Session/ACPSymbolReferenceTests.swift
git commit -m "feat(acp): find symbol mentions whose declaration is gone"
```

---

### Task 3: Warning on the composer badge

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPSymbolChipCell.swift:28-153`
- Modify: `Alas/Sources/ACP/UI/ACPComposer.swift` (coordinator, `makeNSView`, `dismantleNSView`, `restore`, `insertComposerDraft`, `insertSymbolMention`, text view)
- Test: `AlasTests/ACP/UI/ACPComposerDraftBridgeTests.swift`

**Interfaces:**
- Consumes: `ACPSymbolPresence.missing(among:worktreeRoot:)` (Task 2).
- Produces: `ACPSymbolChipCell.isMissing: Bool` (settable); `ACPNSTextView.recheckSymbolPresence()`; `ACPNSTextView.cancelSymbolPresenceCheck()`.

- [ ] **Step 1: Write the failing test**

Add to `ACPComposerDraftBridgeTests` (the suite is already `@MainActor`):

```swift
    @Test("restoring a draft flags a symbol badge whose declaration is gone, and only that one")
    func restoredDraftFlagsMissingSymbolBadges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "struct Present {\n    func here() {}\n}\n".write(
            to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        func uri(_ name: String) -> String {
            ACPSymbolReference.uri(for: .init(path: "a.swift", name: name, kind: .method, container: "Present",
                                              lineRange: 1...1, includeCode: false))
        }
        let textView = ACPNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        let coordinator = ACPInputField.Coordinator(
            worktreeRoot: root, initialDraft: .empty, focusRequest: 0, sendOnEnter: true,
            onDraftChange: { _ in }, onDraftClear: {}, onSubmit: { _, _, _, _, _ in true })
        coordinator.textView = textView
        textView.coordinator = coordinator
        textView.delegate = coordinator

        coordinator.restoreDraftForTesting(
            ACPComposerDraft(segments: [.mention(displayName: "here()", uri: uri("here")),
                                        .mention(displayName: "gone()", uri: uri("gone"))]),
            into: textView)

        func cells() -> [String: ACPSymbolChipCell] {
            var result: [String: ACPSymbolChipCell] = [:]
            let storage = textView.textStorage
            storage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage?.length ?? 0)) { value, _, _ in
                if let chip = value as? ACPMentionChipAttachment, let cell = chip.attachmentCell as? ACPSymbolChipCell {
                    result[chip.uri] = cell
                }
            }
            return result
        }
        let flagged = await awaitCondition(within: .seconds(5)) { cells()[uri("gone")]?.isMissing == true }
        #expect(flagged)
        #expect(cells()[uri("here")]?.isMissing == false)
        textView.cancelSymbolPresenceCheck()
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `xcodebuild ... -only-testing 'AlasTests/ACPComposerDraftBridgeTests/restoredDraftFlagsMissingSymbolBadges()' test`
Expected: build errors `value of type 'ACPSymbolChipCell' has no member 'isMissing'` and `ACPNSTextView has no member 'cancelSymbolPresenceCheck'`.

- [ ] **Step 3: Teach the cell about the warning**

In `ACPSymbolChipCell.swift`, add the state and the segment model, replacing `countText` consumers. Replace lines 47-68 (from `private var containerText` through `fixedWidth`) with:

```swift
    private var containerText: String { symbol.container.map { $0 + "." } ?? "" }
    private var nameText: String { symbol.kind.isCallable ? symbol.name + "()" : symbol.name }
    private var countText: String? {
        guard symbol.includeCode else { return nil }
        let count = symbol.lineRange.count
        return count > ACPSymbolReference.maxExcerptLines
            ? "\(ACPSymbolReference.maxExcerptLines)+ lines"
            : "\(count) line\(count == 1 ? "" : "s")"
    }
    /// Width of the accent edge drawn when code is included.
    private var edgeWidth: CGFloat { symbol.includeCode ? 2 : 0 }

    /// Set by the composer when the declaration can no longer be found. It
    /// changes the cell's width, so whoever sets it invalidates the layout.
    var isMissing = false
    private static let warningText = "⚠ not found"
    private static let warningColor = NSColor.systemOrange
    private static let warningFill = NSColor.systemOrange.withAlphaComponent(0.14)

    /// A trailing segment: the line count, then the warning.
    private struct Segment {
        let text: String
        let color: NSColor
        let fill: NSColor
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        if let countText {
            result.append(Segment(text: countText, color: .secondaryLabelColor, fill: Self.countFill))
        }
        if isMissing {
            result.append(Segment(text: Self.warningText, color: Self.warningColor, fill: Self.warningFill))
        }
        return result
    }

    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private func segmentWidth(_ segment: Segment) -> CGFloat { 10 + width(segment.text, Self.countFont) }

    /// Everything but the label: accent edge, icon, padding, trailing segments.
    private var fixedWidth: CGFloat {
        edgeWidth + 4 + Self.iconSize + 5 + 6 + segments.reduce(0) { $0 + segmentWidth($1) }
    }
```

Replace the `if let countText { ... }` block inside `draw` (the block from `if let countText {` through its closing brace, just before `NSGraphicsContext.restoreGraphicsState()`) with:

```swift
        var segmentEdge = frame.maxX
        for segment in segments.reversed() {
            let segmentRect = NSRect(x: segmentEdge - segmentWidth(segment), y: frame.minY,
                                     width: segmentWidth(segment), height: frame.height)
            segment.fill.setFill()
            segmentRect.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: segmentRect.minX, y: frame.minY, width: 0.5, height: frame.height).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.countFont, .foregroundColor: segment.color]
            let size = (segment.text as NSString).size(withAttributes: attrs)
            (segment.text as NSString).draw(at: NSPoint(x: segmentRect.minX + 5, y: frame.midY - size.height / 2),
                                            withAttributes: attrs)
            segmentEdge = segmentRect.minX
        }
```

- [ ] **Step 4: Check and apply presence on the text view**

In `ACPComposer.swift`, in `ACPNSTextView` next to `private var mentionStart: Int = -1`, add:

```swift
    private var symbolPresenceTask: Task<Void, Never>?
```

Directly above `func insertMention(_ url: URL) -> Bool` (inside the same type), add:

```swift
    /// Distinct symbol-link URIs of the badges in the text.
    private func symbolBadgeURIs() -> [String] {
        guard let textStorage else { return [] }
        var uris: [String] = []
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, _, _ in
            guard let chip = value as? ACPMentionChipAttachment, chip.attachmentCell is ACPSymbolChipCell,
                  !uris.contains(chip.uri) else { return }
            uris.append(chip.uri)
        }
        return uris
    }

    /// Looks again for each symbol badge's declaration and marks the ones that
    /// are gone. A newer check replaces an older one still in flight.
    func recheckSymbolPresence() {
        symbolPresenceTask?.cancel()
        let uris = symbolBadgeURIs()
        guard !uris.isEmpty, let root = coordinator?.worktreeRoot else {
            symbolPresenceTask = nil
            return
        }
        symbolPresenceTask = Task { [weak self] in
            let missing = await ACPSymbolPresence.missing(among: uris, worktreeRoot: root)
            guard !Task.isCancelled, let self else { return }
            self.applySymbolPresence(missing: missing)
        }
    }

    func cancelSymbolPresenceCheck() {
        symbolPresenceTask?.cancel()
        symbolPresenceTask = nil
    }

    /// Applies by URI to the badges now in the text, so a result for a draft
    /// that has since changed cannot flag the wrong badge. The warning changes
    /// a badge's width, so layout is invalidated, not only display.
    private func applySymbolPresence(missing: Set<String>) {
        guard let textStorage, let layoutManager else { return }
        var changed = false
        textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard let chip = value as? ACPMentionChipAttachment,
                  let cell = chip.attachmentCell as? ACPSymbolChipCell else { return }
            let isMissing = missing.contains(chip.uri)
            guard cell.isMissing != isMissing else { return }
            cell.isMissing = isMissing
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
            changed = true
        }
        if changed {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
```

- [ ] **Step 5: Trigger it**

Change `insertSymbolMention` to:

```swift
    @discardableResult
    func insertSymbolMention(_ entry: SymbolEntry, includeCode: Bool) -> Bool {
        let target = ACPSymbolReference.Target(entry: entry, includeCode: includeCode)
        let inserted = insertMention(displayName: target.displayName, uri: ACPSymbolReference.uri(for: target))
        if inserted { recheckSymbolPresence() }
        return inserted
    }
```

In `insertComposerDraft(from:)`, just before its final `return true` (after `typingAttributes = attrs`), add:

```swift
        recheckSymbolPresence()
```

In `Coordinator.restore(_:into:)`, directly after `lastAppliedComposerDraft = draft` (the last line), add:

```swift
            (textView as? ACPNSTextView)?.recheckSymbolPresence()
```

In `Coordinator`, next to `private var upstreamObservations: Set<AnyCancellable> = []`, add:

```swift
        private var presenceObservers: [NSObjectProtocol] = []

        /// Rechecks symbol badges when Alas becomes the active app or this
        /// composer's window becomes key: the files may have changed meanwhile.
        func startSymbolPresenceObservers() {
            guard presenceObservers.isEmpty else { return }
            let center = NotificationCenter.default
            presenceObservers = [
                center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { (self?.textView as? ACPNSTextView)?.recheckSymbolPresence() }
                },
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let textView = self?.textView as? ACPNSTextView,
                              (note.object as? NSWindow) === textView.window else { return }
                        textView.recheckSymbolPresence()
                    }
                },
            ]
        }

        func stopSymbolPresenceObservers() {
            presenceObservers.forEach { NotificationCenter.default.removeObserver($0) }
            presenceObservers.removeAll()
        }
```

In `makeNSView`, directly after `context.coordinator.textView = textView`, add:

```swift
        context.coordinator.startSymbolPresenceObservers()
```

In `dismantleNSView`, inside `if let tv = nsView.documentView as? ACPNSTextView {`, add as the first two lines:

```swift
            tv.cancelSymbolPresenceCheck()
            coordinator.stopSymbolPresenceObservers()
```

- [ ] **Step 6: Run the test and the suites around it**

Run: `xcodebuild ... -only-testing AlasTests/ACPComposerDraftBridgeTests -only-testing AlasTests/ACPSymbolReferenceTests -only-testing AlasTests/ACPMentionPickerTests test`
Expected: all pass, including `restoredDraftFlagsMissingSymbolBadges()`.

- [ ] **Step 7: Look at the warning segment (throwaway, not committed)**

Temporarily add `import SwiftUI` to `ACPSymbolReferenceTests.swift` and this test, run it, read `/tmp/badge-warning.png`, then delete the test, the import, and the PNG:

```swift
    @Test @MainActor func zzScratchBadgeRender() throws {
        let cell = ACPSymbolChipCell(target: target("restore", .method, lines: 3...5, code: true))
        var images: [NSImage] = []
        for missing in [false, true] {
            cell.isMissing = missing
            let size = cell.cellSize
            let image = NSImage(size: NSSize(width: size.width + 8, height: size.height + 8), flipped: true) { _ in
                cell.draw(withFrame: NSRect(x: 4, y: 4, width: size.width, height: size.height), in: nil)
                return true
            }
            images.append(image)
        }
        let sheet = NSImage(size: NSSize(width: images.map(\.size.width).max()! , height: images.reduce(0) { $0 + $1.size.height }), flipped: true) { _ in
            var y: CGFloat = 0
            for image in images { image.draw(at: NSPoint(x: 0, y: y), from: .zero, operation: .sourceOver, fraction: 1); y += image.size.height }
            return true
        }
        let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/badge-warning.png"))
    }
```

Expected: two rows; the second has an orange `⚠ not found` segment after `N lines`, and the pill is wider. Dark-theme colors may differ slightly from the app because the scratch image uses the system appearance.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPSymbolChipCell.swift Alas/Sources/ACP/UI/ACPComposer.swift AlasTests/ACP/UI/ACPComposerDraftBridgeTests.swift
git commit -m "feat(acp): warn on a composer symbol badge whose declaration is gone"
```

---

### Task 4: What a sent badge's preview shows

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPSymbolHoverPreview.swift` (`Loaded`, `load`, `apply`, new `sentWindow`)
- Create: `Alas/Sources/ACP/UI/ACPSymbolSentPreview.swift` (the pure part only in this task)
- Modify: `AlasTests/ACP/Session/ACPSymbolReferenceTests.swift` (existing `.found(...)` call sites, new tests)

**Interfaces:**
- Consumes: `ACPSymbolReference.contentHash(of:)` (Task 1), `ACPSymbolSnapshot`.
- Produces:
  - `ACPSymbolHoverPreview.Loaded.found(lineRange: ClosedRange<Int>, window: Window, contentHash: String)` (a new third associated value).
  - `ACPSymbolHoverPreview.sentWindow(from snapshot: ACPSymbolSnapshot) -> Window?`
  - `struct ACPSymbolSentPreview: Equatable { enum Source { case sent, current }; enum Note { case changedSinceSent, noLongerFound, notFoundWhenSent; var text: String }; let source: Source; let canShowCurrent: Bool; let note: Note?; static func make(snapshot: ACPSymbolSnapshot?, live: ACPSymbolHoverPreview.Loaded?) -> ACPSymbolSentPreview }`

- [ ] **Step 1: Write the failing tests**

Add to `ACPSymbolReferenceTests`:

```swift
    private static func liveFound(hash: String) -> ACPSymbolHoverPreview.Loaded {
        .found(lineRange: 0...0, window: ACPSymbolHoverPreview.window(declaration: "x", startLine: 0), contentHash: hash)
    }

    private static func snapshot(excerpt: String?, hash: String = "h", found: Bool = true,
                                 range: ClosedRange<Int> = 10...12) -> ACPSymbolSnapshot {
        ACPSymbolSnapshot(lineRange: range, contentHash: found ? hash : "", excerpt: excerpt, truncated: false, found: found)
    }

    @Test("a sent badge's preview follows the snapshot and the file as it is now")
    func sentPreviewCases() {
        typealias Preview = ACPSymbolSentPreview
        // Code sent, file unchanged: the excerpt, switchable to current once read.
        #expect(Preview.make(snapshot: Self.snapshot(excerpt: "x"), live: nil)
            == .init(source: .sent, canShowCurrent: false, note: nil))
        #expect(Preview.make(snapshot: Self.snapshot(excerpt: "x"), live: Self.liveFound(hash: "h"))
            == .init(source: .sent, canShowCurrent: true, note: nil))
        // Code sent, file changed since.
        #expect(Preview.make(snapshot: Self.snapshot(excerpt: "x"), live: Self.liveFound(hash: "other"))
            == .init(source: .sent, canShowCurrent: true, note: .changedSinceSent))
        // Code sent, symbol gone now: the excerpt stays, with a note.
        #expect(Preview.make(snapshot: Self.snapshot(excerpt: "x"), live: .missing)
            == .init(source: .sent, canShowCurrent: false, note: .noLongerFound))
        // Code not sent: current code, noting a change.
        #expect(Preview.make(snapshot: Self.snapshot(excerpt: nil), live: Self.liveFound(hash: "other"))
            == .init(source: .current, canShowCurrent: false, note: .changedSinceSent))
        #expect(Preview.make(snapshot: Self.snapshot(excerpt: nil), live: Self.liveFound(hash: "h"))
            == .init(source: .current, canShowCurrent: false, note: nil))
        #expect(Preview.make(snapshot: Self.snapshot(excerpt: nil), live: .missing)
            == .init(source: .current, canShowCurrent: false, note: .noLongerFound))
        // Not found when sent wins over any live result.
        #expect(Preview.make(snapshot: Self.snapshot(excerpt: nil, found: false), live: Self.liveFound(hash: "other"))
            == .init(source: .current, canShowCurrent: false, note: .notFoundWhenSent))
        // Older messages have no snapshot: current code, no note.
        #expect(Preview.make(snapshot: nil, live: Self.liveFound(hash: "other"))
            == .init(source: .current, canShowCurrent: false, note: nil))
    }

    @Test("a cut excerpt previews 40 lines from the sent start, and a fresh hash of the full code matches the stored one")
    func sentWindowAndHashOfCutExcerpt() throws {
        let full = (0..<500).map { "line \($0)" }.joined(separator: "\n")
        let excerpt = ACPSymbolReference.excerpt(full)
        #expect(excerpt.truncated)
        let stored = ACPSymbolSnapshot(lineRange: 99...598, contentHash: ACPSymbolReference.contentHash(of: full),
                                       excerpt: excerpt.text, truncated: true, found: true)
        let window = try #require(ACPSymbolHoverPreview.sentWindow(from: stored))
        #expect(window.firstLineNumber == 100)
        #expect(window.shownLines == 40)
        #expect(window.hiddenLines == excerpt.text.components(separatedBy: "\n").count - 40)
        // The live code is the full declaration, so the cut excerpt must not read as a change.
        #expect(ACPSymbolSentPreview.make(snapshot: stored, live: Self.liveFound(hash: ACPSymbolReference.contentHash(of: full))).note == nil)
        #expect(ACPSymbolHoverPreview.sentWindow(from: Self.snapshot(excerpt: nil)) == nil)
    }
```

Update the two existing `.found(...)` call sites in this file for the new associated value: in `hoverReservesLoadedHeight`, change `model.apply(.found(lineRange: target.lineRange, window: ACPSymbolHoverPreview.window(declaration: declaration, startLine: 10)), theme: nil)` to pass `contentHash: "h"` as a third argument to `.found`; in `hoverFound`, change the returned value to `.found(lineRange: 0...0, window: ACPSymbolHoverPreview.window(declaration: text, startLine: 0), contentHash: "h")`.

- [ ] **Step 2: Run to see it fail**

Run: `xcodebuild ... -only-testing AlasTests/ACPSymbolReferenceTests test`
Expected: build errors (`extra argument 'contentHash'`, `cannot find 'ACPSymbolSentPreview'`, `no member 'sentWindow'`).

- [ ] **Step 3: Carry the hash on live results**

In `ACPSymbolHoverPreview.swift`:

Change `Loaded`:

```swift
    enum Loaded: Equatable, Sendable {
        /// `contentHash` is `ACPSymbolReference.contentHash(of:)` over the full
        /// declaration, not the capped window.
        case found(lineRange: ClosedRange<Int>, window: Window, contentHash: String)
        case missing
    }
```

In `load`, replace the `return .found(...)` with:

```swift
        return .found(lineRange: resolution.lineRange,
                      window: window(declaration: declaration, startLine: resolution.lineRange.lowerBound),
                      contentHash: ACPSymbolReference.contentHash(of: declaration))
```

In `ACPSymbolHoverModel.apply`, change the pattern `if case .found(let foundRange, let window) = loaded {` to `if case .found(let foundRange, let window, _) = loaded {`.

Add, after `placeholderWindow`:

```swift
    /// The stored excerpt of a sent snapshot as a preview window, numbered from
    /// the sent range. Nil when the code was not sent.
    static func sentWindow(from snapshot: ACPSymbolSnapshot) -> Window? {
        guard let excerpt = snapshot.excerpt else { return nil }
        return window(declaration: excerpt, startLine: snapshot.lineRange.lowerBound)
    }
```

- [ ] **Step 4: The pure decision**

Create `Alas/Sources/ACP/UI/ACPSymbolSentPreview.swift`:

```swift
import SwiftUI

/// What the transcript popover of a sent symbol badge shows, decided from the
/// snapshot stored with the message and the file as it is now.
struct ACPSymbolSentPreview: Equatable {
    enum Source: Hashable { case sent, current }

    enum Note: Equatable {
        case changedSinceSent
        case noLongerFound
        case notFoundWhenSent

        var text: String {
            switch self {
            case .changedSinceSent: "Changed since sent"
            case .noLongerFound: "No longer found"
            case .notFoundWhenSent: "Not found when sent"
            }
        }
    }

    /// The code shown first. `.current` shows live code, a skeleton until read.
    let source: Source
    /// Whether the popover can switch to the current code: code was sent and
    /// the symbol exists now.
    let canShowCurrent: Bool
    let note: Note?

    /// `live` is nil until the file has been read.
    static func make(snapshot: ACPSymbolSnapshot?, live: ACPSymbolHoverPreview.Loaded?) -> ACPSymbolSentPreview {
        guard let snapshot else { return ACPSymbolSentPreview(source: .current, canShowCurrent: false, note: nil) }
        var liveHash: String?
        var liveMissing = false
        switch live {
        case .found(_, _, let hash)?: liveHash = hash
        case .missing?: liveMissing = true
        case nil: break
        }
        let sentCode = snapshot.excerpt != nil
        let note: Note? = if !snapshot.found {
            .notFoundWhenSent
        } else if liveMissing {
            .noLongerFound
        } else if let liveHash, liveHash != snapshot.contentHash {
            .changedSinceSent
        } else {
            nil
        }
        return ACPSymbolSentPreview(source: sentCode ? .sent : .current,
                                    canShowCurrent: sentCode && liveHash != nil, note: note)
    }
}
```

- [ ] **Step 5: Run xcodegen, then the suites**

Run: `xcodegen && xcodebuild ... -only-testing AlasTests/ACPSymbolReferenceTests -only-testing AlasTests/ACPMentionPickerTests test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPSymbolHoverPreview.swift Alas/Sources/ACP/UI/ACPSymbolSentPreview.swift Alas.xcodeproj/project.pbxproj AlasTests/ACP/Session/ACPSymbolReferenceTests.swift
git commit -m "feat(acp): decide what a sent symbol preview shows"
```

---

### Task 5: Sent hover model and view

**Files:**
- Modify: `Alas/Sources/ACP/UI/ACPSymbolHoverPreview.swift` (`ACPSymbolHoverCard` accessory slot)
- Modify: `Alas/Sources/ACP/UI/ACPSymbolSentPreview.swift` (append model and view)

**Interfaces:**
- Consumes: `ACPSymbolSentPreview.make`, `ACPSymbolHoverPreview.sentWindow(from:)`, `ACPSymbolHoverPreview.load`, `ACPSymbolHoverCache.shared`, `ACPSymbolHoverModel(target:typography:)`, `ACPSymbolHoverModel.apply(_:theme:animated:)`.
- Produces: `ACPSymbolHoverCard` generic over an `accessory` view (existing `ACPSymbolHoverCard(model:maxCodeHeight:)` keeps working); `ACPSymbolSentHoverView(target:snapshot:root:typography:theme:)`.

- [ ] **Step 1: Give the card an accessory slot**

In `ACPSymbolHoverPreview.swift`, replace the card's declaration and the start of its `body`:

```swift
struct ACPSymbolHoverCard<Accessory: View>: View {
    @ObservedObject var model: ACPSymbolHoverModel
    /// Tallest the code area may get before it scrolls.
    let maxCodeHeight: CGFloat
    /// Shown between the header and the code.
    let accessory: Accessory

    init(model: ACPSymbolHoverModel, maxCodeHeight: CGFloat, @ViewBuilder accessory: () -> Accessory) {
        self.model = model
        self.maxCodeHeight = maxCodeHeight
        self.accessory = accessory()
    }
```

In `body`, change `header` followed by `switch model.state {` to:

```swift
            header
            accessory
            switch model.state {
```

After the card, add:

```swift
extension ACPSymbolHoverCard where Accessory == EmptyView {
    init(model: ACPSymbolHoverModel, maxCodeHeight: CGFloat) {
        self.init(model: model, maxCodeHeight: maxCodeHeight) { EmptyView() }
    }
}
```

- [ ] **Step 2: The model**

Append to `ACPSymbolSentPreview.swift`:

```swift
/// Drives the popover of a sent badge: the stored excerpt, if any, and the
/// code as it is now, read once the popover opens.
@MainActor
final class ACPSymbolSentHoverModel: ObservableObject {
    let snapshot: ACPSymbolSnapshot?
    /// Shows the stored excerpt; nil when code was not sent.
    let sent: ACPSymbolHoverModel?
    let current: ACPSymbolHoverModel
    @Published private(set) var preview: ACPSymbolSentPreview
    /// Which code the card shows; the user switches it.
    @Published var shown: ACPSymbolSentPreview.Source
    /// What the live read looks for: the symbol where it was when sent.
    private let sentTarget: ACPSymbolReference.Target

    init(target: ACPSymbolReference.Target, snapshot: ACPSymbolSnapshot?, typography: ACPChatTypography, theme: Theme?) {
        let sentTarget = ACPSymbolReference.Target(
            path: target.path, name: target.name, kind: target.kind, container: target.container,
            lineRange: snapshot?.lineRange ?? target.lineRange, includeCode: target.includeCode)
        self.snapshot = snapshot
        self.sentTarget = sentTarget
        self.current = ACPSymbolHoverModel(target: sentTarget, typography: typography)
        if let snapshot, let window = ACPSymbolHoverPreview.sentWindow(from: snapshot) {
            let model = ACPSymbolHoverModel(target: sentTarget, typography: typography)
            model.apply(.found(lineRange: snapshot.lineRange, window: window, contentHash: snapshot.contentHash), theme: theme)
            self.sent = model
        } else {
            self.sent = nil
        }
        let initial = ACPSymbolSentPreview.make(snapshot: snapshot, live: nil)
        self.preview = initial
        self.shown = initial.source
    }

    var shownModel: ACPSymbolHoverModel { shown == .sent ? (sent ?? current) : current }

    /// Shows what an earlier hover read, then reads the file again. Live reads
    /// share `ACPSymbolHoverCache`; the stored excerpt never enters it.
    func load(root: URL, theme: Theme?) async {
        let cache = ACPSymbolHoverCache.shared
        let cached = cache.loaded(root: root, target: sentTarget)
        if let cached { applyLive(cached, theme: theme, animated: false) }
        guard let loaded = await ACPSymbolHoverPreview.load(sentTarget, root: root), !Task.isCancelled else { return }
        cache.store(loaded, root: root, target: sentTarget)
        if loaded != cached { applyLive(loaded, theme: theme, animated: true) }
    }

    private func applyLive(_ loaded: ACPSymbolHoverPreview.Loaded, theme: Theme?, animated: Bool) {
        current.apply(loaded, theme: theme, animated: animated)
        preview = ACPSymbolSentPreview.make(snapshot: snapshot, live: loaded)
    }
}
```

- [ ] **Step 3: The view**

Append:

```swift
/// The popover of a sent symbol badge.
struct ACPSymbolSentHoverView: View {
    @StateObject private var model: ACPSymbolSentHoverModel
    let root: URL
    let theme: Theme

    init(target: ACPSymbolReference.Target, snapshot: ACPSymbolSnapshot?, root: URL,
         typography: ACPChatTypography, theme: Theme) {
        _model = StateObject(wrappedValue: ACPSymbolSentHoverModel(
            target: target, snapshot: snapshot, typography: typography, theme: theme))
        self.root = root
        self.theme = theme
    }

    private static var maxCodeHeight: CGFloat {
        min(420, (NSScreen.main?.visibleFrame.height ?? 840) / 2)
    }

    var body: some View {
        ACPSymbolHoverCard(model: model.shownModel, maxCodeHeight: Self.maxCodeHeight) {
            if model.snapshot != nil { bar }
        }
        .task { await model.load(root: root, theme: theme) }
    }

    /// Reserved whenever a snapshot exists, so a late note or toggle cannot
    /// change the popover's height.
    private var bar: some View {
        HStack(spacing: 8) {
            if model.sent != nil {
                Picker("", selection: $model.shown) {
                    Text("Sent").tag(ACPSymbolSentPreview.Source.sent)
                    Text(model.preview.note == .changedSinceSent ? "Current (changed)" : "Current")
                        .tag(ACPSymbolSentPreview.Source.current)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .disabled(!model.preview.canShowCurrent)
            }
            if let note = model.preview.note {
                Text(note.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }
}
```

- [ ] **Step 4: Build and run the existing suites**

Run: `xcodebuild ... -only-testing AlasTests/ACPSymbolReferenceTests -only-testing AlasTests/ACPMentionPickerTests test`
Expected: builds; all pass. The existing composer hover (`ACPFileMentionHoverController`) still constructs `ACPSymbolHoverCard(model:maxCodeHeight:)` through the new extension.

- [ ] **Step 5: Look at both popover states (throwaway, not committed)**

Temporarily add `import SwiftUI` and `import AppKit` to `ACPSymbolReferenceTests.swift` and this test; run it; read `/tmp/sent-sent.png` and `/tmp/sent-current.png`; then delete the test, imports, and PNGs:

```swift
    @Test @MainActor func zzScratchSentHover() throws {
        let target = ACPSymbolReference.Target(path: "a.swift", name: "restore", kind: .method, container: "S",
                                               lineRange: 0...5, includeCode: true)
        let code = (0..<6).map { "    let value\($0) = try await store.load(\($0))" }.joined(separator: "\n")
        let snapshot = ACPSymbolSnapshot(lineRange: 0...5, contentHash: "h", excerpt: code, truncated: false, found: true)
        let model = ACPSymbolSentHoverModel(target: target, snapshot: snapshot, typography: .default, theme: nil)
        for (name, source) in [("sent", ACPSymbolSentPreview.Source.sent), ("current", .current)] {
            model.shown = source
            let view = NSHostingView(rootView: ACPSymbolHoverCard(model: model.shownModel, maxCodeHeight: 420) {
                HStack { Text("Sent / Current bar").font(.system(size: 11)); Spacer(minLength: 0) }.frame(height: 22)
            }.background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: .darkAqua)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/sent-\(name).png"))
        }
    }
```

Expected: the "sent" image shows the six excerpt lines under the header and the bar row; the "current" image shows the loading skeleton at the same height. This checks the accessory slot and the shared sizing, not the live read.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/ACP/UI/ACPSymbolHoverPreview.swift Alas/Sources/ACP/UI/ACPSymbolSentPreview.swift
git commit -m "feat(acp): sent symbol preview model and popover view"
```

---

### Task 6: Transcript badge

**Files:**
- Create: `Alas/Sources/ACP/UI/ACPSymbolBadge.swift`
- Modify: `Alas/Sources/ACP/UI/ACPSymbolChipCell.swift` (share line-count text and fills)
- Modify: `Alas/Sources/ACP/UI/ACPTranscriptMessageRows.swift:5-67` (`UserMessageRow`)
- Modify: `Alas/Sources/ACP/UI/ACPTranscriptRowContent.swift:217-226` (pass the root)
- Modify: `Alas/Sources/ACP/UI/ACPSubagentRowView.swift:198-263`

**Interfaces:**
- Consumes: `ACPSymbolSentHoverView` (Task 5), `ACPSymbolReference.openURL(for:snapshot:)`, `ACPImageChipHoverController.hoverDelay`.
- Produces: `ACPSymbolBadge(target:snapshot:root:typography:)`; `ACPSymbolReference.Target.lineCountText(for:)`.

- [ ] **Step 1: Share the line-count text and the fills**

In `ACPSymbolChipCell.swift`, add at the end of the file:

```swift
extension ACPSymbolReference.Target {
    /// The badge's trailing segment when code is included: `N lines`, or
    /// `400+ lines` past the excerpt cap.
    static func lineCountText(for range: ClosedRange<Int>) -> String {
        let count = range.count
        return count > ACPSymbolReference.maxExcerptLines
            ? "\(ACPSymbolReference.maxExcerptLines)+ lines"
            : "\(count) line\(count == 1 ? "" : "s")"
    }
}
```

In the cell, replace the `countText` property with:

```swift
    private var countText: String? {
        symbol.includeCode ? ACPSymbolReference.Target.lineCountText(for: symbol.lineRange) : nil
    }
```

Change `private static let pillFill` and `private static let countFill` to `static let` (drop `private`) so the SwiftUI badge uses the same colors.

- [ ] **Step 2: The badge**

Create `Alas/Sources/ACP/UI/ACPSymbolBadge.swift`:

```swift
import AppKit
import SwiftUI

/// A sent symbol mention in the transcript: the composer badge's code-token
/// look. Click opens the symbol in the editor at the range that was sent;
/// hover shows what was sent, or the code now.
struct ACPSymbolBadge: View {
    let target: ACPSymbolReference.Target
    let snapshot: ACPSymbolSnapshot?
    let root: URL?
    let typography: ACPChatTypography
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false
    @State private var showsPreview = false

    private var containerText: String { target.container.map { $0 + "." } ?? "" }
    private var nameText: String { target.kind.isCallable ? target.name + "()" : target.name }
    private var countText: String? {
        target.includeCode
            ? ACPSymbolReference.Target.lineCountText(for: snapshot?.lineRange ?? target.lineRange) : nil
    }

    private var label: AttributedString {
        var container = AttributedString(containerText)
        container.foregroundColor = Color(nsColor: SymbolKind.class.badgeLabelColor)
        var name = AttributedString(nameText)
        name.foregroundColor = Color(nsColor: target.kind.badgeLabelColor)
        return container + name
    }

    var body: some View {
        Button {
            if let url = ACPSymbolReference.openURL(for: target, snapshot: snapshot) { openURL(url) }
        } label: {
            pill
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .onDisappear {
            isHovering = false
            showsPreview = false
        }
        .task(id: isHovering) {
            guard isHovering, root != nil else {
                showsPreview = false
                return
            }
            try? await Task.sleep(for: .seconds(ACPImageChipHoverController.hoverDelay))
            if !Task.isCancelled { showsPreview = true }
        }
        .popover(isPresented: $showsPreview, arrowEdge: .bottom) {
            if let root {
                ACPSymbolSentHoverView(target: target, snapshot: snapshot, root: root,
                                       typography: typography, theme: theme)
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 0) {
            if target.includeCode {
                Rectangle().fill(Color(nsColor: .controlAccentColor)).frame(width: 2)
            }
            HStack(spacing: 5) {
                Text(target.kind.badgeLetter)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color(nsColor: target.kind.badgeLabelColor))
                    .frame(width: 13, height: 13)
                    .background(Color(nsColor: target.kind.badgeBackground), in: RoundedRectangle(cornerRadius: 3))
                Text(label)
                    .font(Font(ACPMentionChipMetrics.labelFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 4)
            .padding(.trailing, 6)
            if let countText {
                HStack(spacing: 0) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5)
                    Text(countText)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .padding(.horizontal, 5)
                }
                .background(Color(nsColor: ACPSymbolChipCell.countFill))
            }
        }
        .frame(height: 20)
        .background(Color(nsColor: ACPSymbolChipCell.pillFill))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5).strokeBorder(
                target.includeCode
                    ? Color(nsColor: NSColor.controlAccentColor.withAlphaComponent(0.6))
                    : Color(nsColor: .separatorColor),
                lineWidth: 0.75)
        )
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 3: Use it in the user bubble**

In `ACPTranscriptMessageRows.swift`, add to `UserMessageRow` after `let chipsAbsolutePaths: Bool`:

```swift
    /// Where symbol previews read files; nil when the row has no worktree.
    let worktreeRoot: URL?
```

Replace the lines from `if let target = ACPSymbolReference.target(fromURI: a.uri) {` through the `} else {` that follows the symbol `FileChip` (the one with `iconSystemName: "curlybraces"`) with the following; the original `FileChip(path: a.name ?? a.uri, ...)` and its closing braces stay:

```swift
                                if let target = ACPSymbolReference.target(fromURI: a.uri) {
                                    ACPSymbolBadge(target: target, snapshot: a.symbol,
                                                   root: worktreeRoot, typography: typography)
                                } else {
```

(the existing `} else { FileChip(path: a.name ?? a.uri, ...) }` stays as it is). In `ACPTranscriptRowContent.swift`, add `worktreeRoot: trustedImageRoot,` after the `chipsAbsolutePaths: ...` argument of the `UserMessageRow(` call.

- [ ] **Step 4: Use it in the subagent prompt row**

In `ACPSubagentRowView.swift`, change the `.user` case to:

```swift
        case .user(_, _, let text, let attachments, _, _):
            ACPSubagentPromptRow(text: text, attachments: attachments, typography: typography, root: trustedImageRoot)
```

Add `let typography: ACPChatTypography` and `let root: URL?` to `ACPSubagentPromptRow` (after `let attachments: [ACPMessage.Attachment]`). Replace the lines from `if let target = ACPSymbolReference.target(fromURI: attachment.uri) {` through the `} else {` that follows the symbol `FileChip` (the one with `iconSystemName: "curlybraces"` and its `action:`) with the following; the original `FileChip(path: attachment.name ?? attachment.uri, ...)` stays:

```swift
                        if let target = ACPSymbolReference.target(fromURI: attachment.uri) {
                            ACPSymbolBadge(target: target, snapshot: attachment.symbol, root: root, typography: typography)
                        } else {
```

(the existing `FileChip(path: attachment.name ?? attachment.uri, ... iconSystemName: "at")` branch stays). Remove the now unused `@Environment(\.openURL) private var openURL` from `ACPSubagentPromptRow` if nothing else in that view uses it.

- [ ] **Step 5: xcodegen, build, run the suites**

Run: `xcodegen && xcodebuild ... -only-testing AlasTests/ACPSymbolReferenceTests -only-testing AlasTests/ACPTranscriptRowContentTests -only-testing AlasTests/ACPSubagentSessionTests test`
Expected: builds; all pass. If the compiler reports an unused `openURL` or a missing argument at a `UserMessageRow(` call site in a test, fix that call site.

- [ ] **Step 6: Commit**

```bash
git add Alas/Sources/ACP/UI Alas.xcodeproj/project.pbxproj
git commit -m "feat(acp): show sent symbols as badges with a hover preview"
```

---

### Task 7: Wrap-up

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/plans/2026-10-06-composer-symbol-mentions-design.md` (only if behavior drifted from it)

- [ ] **Step 1: Run the focused suites together**

Run: `xcodebuild ... -only-testing AlasTests/ACPSymbolReferenceTests -only-testing AlasTests/ACPComposerDraftBridgeTests -only-testing AlasTests/ACPMentionPickerTests -only-testing AlasTests/ACPTranscriptRowContentTests -only-testing AlasTests/ACPMessageWireTests test`
Expected: `Test run with N tests ... passed`. Read the `Test run with` line to confirm the suites ran.

- [ ] **Step 2: Build and launch for a hands-on pass**

Run the build as in `AGENTS.md`, delete a stale `AlasTests.xctest` from the built app's `PlugIns` if code signing fails, then `open -n` the app. Check by hand:
1. In a composer, insert a symbol badge, then delete or rename that function in the file in another app and come back to Alas: the badge shows `⚠ not found` and widens; undo the edit and come back: the warning goes away.
2. Send a message with a symbol (with and without code). In the transcript, the badge looks like the composer's; hovering shows the popover; with code, "Sent" is shown first and "Current" becomes available; click opens the editor at the range.
3. Edit the symbol after sending: hover shows "Changed since sent" (code not sent) or "Current (changed)" (code sent).
4. A message sent before this change (no snapshot) shows current code and no note.

- [ ] **Step 3: Changelog**

After the PR number is known, add under `## [Unreleased]` → `### ✨ Features` in `CHANGELOG.md`:

```markdown
- Warn on a composer symbol badge when its declaration is gone, and show sent symbols in the transcript as badges that preview what was sent or the code now (#NNNN).
```

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): note symbol mention phase 2"
```
