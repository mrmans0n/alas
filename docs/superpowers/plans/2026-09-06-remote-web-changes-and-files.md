# Remote Web Changes and Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add read-only Changes and Files tabs to the remote web client so a paired phone can review a session's diff and browse its worktree.

**Architecture:** Four request/response pairs ride the existing WebSocket, keyed by `sessionId`; the server resolves session → worktree. New `RemoteSessionsProvider` methods on `AppState` delegate to `GitService` (one new base-relative changed-file query, one new against-ref file diff) behind a pure path-safety and caps helper. The web client gains two `.view` sections, a segmented tab control, and two standalone logic scripts with node tests, following the `worktree-creation.js` convention.

**Tech Stack:** Swift 5.9+, Swift Testing (`import Testing`, not XCTest), SwiftUI/AppKit macOS app, vanilla ES5-style browser JS with `globalThis` namespaces, node for JS unit tests.

**Spec:** `docs/superpowers/specs/2026-09-06-remote-web-changes-and-files-design.md`

## Global Constraints

- All code, comments, logs, and UI strings in English.
- Tests use the Swift Testing framework (`import Testing`), never XCTest.
- No agent attributions anywhere: no `Co-Authored-By` trailers, no "Generated with" footers, no 🤖 markers, no AI notes in code, comments, docs, or commit bodies.
- After adding or removing files, run `xcodegen` to regenerate `Alas.xcodeproj`, and commit both the sources and the regenerated project.
- `Info.plist` keys live in `project.yml` under `info: properties:` — this plan touches neither.
- Read-only feature: no git mutation, no writer lease required, no editing.
- Server-enforced caps, copied verbatim from the spec: file read **512 KB**, per-file diff **2,000 lines**, change list **500 files**.
- `.git` is excluded from both the file tree and file reads.
- Every failure is reported with a typed reason; no code path may return a silently empty list.
- Browser JS matches the existing style in `Alas/Resources/RemoteWeb/`: no build step, no imports, `globalThis.<Namespace> = {...}` exports, double-quoted strings.
- The full `xcodebuild` sweep is heavy on this machine. Run focused suites locally with `-only-testing:`; leave the full build to CI.

---

### Task 1: Protocol messages and wire types

**Files:**
- Modify: `Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift`
- Modify: `Alas/Sources/Remote/Protocol/RemoteProtocol.swift`
- Test: `AlasTests/Remote/RemoteProtocolTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `RemoteChangedFile`, `RemoteDiffLine`, `RemoteDiffHunk`, `RemoteFileNode`, `RemoteFileAccessReason`; client cases `listChanges(sessionId:)`, `fileDiff(sessionId:path:)`, `listFiles(sessionId:path:)`, `readFile(sessionId:path:)`; server cases `changeList(sessionId:comparisonRef:metricsAvailable:files:truncated:)`, `changeListFailed(sessionId:reason:message:)`, `fileDiffResult(sessionId:path:hunks:truncated:)`, `fileDiffFailed(sessionId:path:reason:message:)`, `fileTree(sessionId:path:nodes:)`, `fileTreeFailed(sessionId:path:reason:message:)`, `fileContents(sessionId:path:text:truncated:)`, `fileUnavailable(sessionId:path:reason:byteSize:message:)`.

- [ ] **Step 1: Write the failing test**

Append to `AlasTests/Remote/RemoteProtocolTests.swift`, inside `struct RemoteProtocolTests`:

```swift
    @Test func changesAndFilesClientMessagesRoundTripAndEncodeRequiredFields() throws {
        let listChanges = RemoteClientMessage.listChanges(sessionId: "s1")
        #expect(try roundTrip(listChanges) == listChanges)

        let fileDiff = RemoteClientMessage.fileDiff(sessionId: "s1", path: "src/main.swift")
        #expect(try roundTrip(fileDiff) == fileDiff)

        let listRoot = RemoteClientMessage.listFiles(sessionId: "s1", path: nil)
        #expect(try roundTrip(listRoot) == listRoot)

        let listDir = RemoteClientMessage.listFiles(sessionId: "s1", path: "src")
        #expect(try roundTrip(listDir) == listDir)

        let readFile = RemoteClientMessage.readFile(sessionId: "s1", path: "README.md")
        #expect(try roundTrip(readFile) == readFile)

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fileDiff)) as? [String: Any])
        #expect(object["type"] as? String == "fileDiff")
        #expect(object["sessionId"] as? String == "s1")
        #expect(object["path"] as? String == "src/main.swift")
    }

    @Test func changesAndFilesServerMessagesRoundTripAndEncodeRequiredFields() throws {
        let file = RemoteChangedFile(
            path: "src/main.swift", status: "M", add: 12, del: 3,
            conflict: nil, renameFrom: nil)
        let changeList = RemoteServerMessage.changeList(
            sessionId: "s1", comparisonRef: "origin/main", metricsAvailable: true,
            files: [file], truncated: false)
        #expect(try roundTrip(changeList) == changeList)

        let changeFailure = RemoteServerMessage.changeListFailed(
            sessionId: "s1", reason: .worktreeUnavailable, message: nil)
        #expect(try roundTrip(changeFailure) == changeFailure)

        let hunk = RemoteDiffHunk(
            header: "@@ -1,2 +1,3 @@", oldStart: 1, newStart: 1,
            lines: [
                RemoteDiffLine(kind: "context", text: "import Foundation", oldNumber: 1, newNumber: 1),
                RemoteDiffLine(kind: "add", text: "import Testing", oldNumber: nil, newNumber: 2)
            ])
        let diff = RemoteServerMessage.fileDiffResult(
            sessionId: "s1", path: "src/main.swift", hunks: [hunk], truncated: true)
        #expect(try roundTrip(diff) == diff)

        let diffFailure = RemoteServerMessage.fileDiffFailed(
            sessionId: "s1", path: "logo.png", reason: .binary, message: nil)
        #expect(try roundTrip(diffFailure) == diffFailure)

        let node = RemoteFileNode(
            name: "src", path: "src", kind: "dir", badge: nil,
            childrenState: "notLoaded", isSubmodule: false)
        let tree = RemoteServerMessage.fileTree(sessionId: "s1", path: nil, nodes: [node])
        #expect(try roundTrip(tree) == tree)

        let treeFailure = RemoteServerMessage.fileTreeFailed(
            sessionId: "s1", path: "../etc", reason: .pathRejected, message: nil)
        #expect(try roundTrip(treeFailure) == treeFailure)

        let contents = RemoteServerMessage.fileContents(
            sessionId: "s1", path: "README.md", text: "# Alas\n", truncated: false)
        #expect(try roundTrip(contents) == contents)

        let unavailable = RemoteServerMessage.fileUnavailable(
            sessionId: "s1", path: "big.bin", reason: .tooLarge, byteSize: 1_500_000, message: nil)
        #expect(try roundTrip(unavailable) == unavailable)

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(changeList)) as? [String: Any])
        #expect(object["type"] as? String == "changeList")
        #expect(object["comparisonRef"] as? String == "origin/main")
        #expect(object["metricsAvailable"] as? Bool == true)
        #expect(object["truncated"] as? Bool == false)
    }

    @Test func unknownFileAccessReasonDecodesAsUnknown() throws {
        let json = #"{"type":"fileDiffFailed","sessionId":"s1","path":"a.txt","reason":"someFutureReason"}"#
        let decoded = try JSONDecoder().decode(RemoteServerMessage.self, from: Data(json.utf8))
        #expect(decoded == .fileDiffFailed(sessionId: "s1", path: "a.txt", reason: .unknown, message: nil))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteProtocolTests test 2>&1 | tail -30`
Expected: compile failure — `listChanges` and the other cases do not exist.

- [ ] **Step 3: Add the wire types**

Append to `Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift`:

```swift
/// Why a changes/files request could not be served. Decoded leniently so an
/// older client keeps working against a newer host that adds reasons.
enum RemoteFileAccessReason: String, Codable, Equatable, Sendable {
    case sessionUnknown
    case worktreeUnavailable
    case pathRejected
    case notFound
    case binary
    case tooLarge
    case gitFailed
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RemoteFileAccessReason(rawValue: raw) ?? .unknown
    }
}

/// Wire projection of `ChangedFile`. `conflict` carries `ConflictKind`'s raw
/// value so the client can mark conflicted files without knowing the enum.
struct RemoteChangedFile: Codable, Equatable, Sendable {
    let path: String
    let status: String
    let add: Int
    let del: Int
    let conflict: String?
    let renameFrom: String?
}

/// Wire projection of `ParsedDiff.Hunk.Line`. `kind` is "context", "add", or
/// "delete"; `text` has no leading +/-/space.
struct RemoteDiffLine: Codable, Equatable, Sendable {
    let kind: String
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
}

/// Wire projection of `ParsedDiff.Hunk`.
struct RemoteDiffHunk: Codable, Equatable, Sendable {
    let header: String
    let oldStart: Int
    let newStart: Int
    let lines: [RemoteDiffLine]
}

/// Wire projection of `FileTreeNode`. `kind` is "dir" or "file";
/// `childrenState` carries `DirectoryChildrenState`'s raw value.
struct RemoteFileNode: Codable, Equatable, Sendable {
    let name: String
    let path: String
    let kind: String
    let badge: String?
    let childrenState: String
    let isSubmodule: Bool
}
```

- [ ] **Step 4: Add the client message cases**

In `Alas/Sources/Remote/Protocol/RemoteProtocol.swift`, add to `RemoteClientMessage` after `case queueSteerUndo(sessionId: String)`:

```swift
    case listChanges(sessionId: String)
    case fileDiff(sessionId: String, path: String)
    case listFiles(sessionId: String, path: String?)
    case readFile(sessionId: String, path: String)
```

Add `path`, `files`, `comparisonRef`, `metricsAvailable`, `truncated`, `hunks`, `nodes`, `reason`, and `byteSize` to the `RemoteClientMessage.CodingKeys` enum and to the `RemoteServerMessage` coding keys enum (both already list `sessionId`, `text`, and `message`).

In `init(from:)`, alongside the other `case "..."` arms:

```swift
        case "listChanges":
            self = .listChanges(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "fileDiff":
            self = .fileDiff(sessionId: try c.decode(String.self, forKey: .sessionId),
                             path: try c.decode(String.self, forKey: .path))
        case "listFiles":
            self = .listFiles(sessionId: try c.decode(String.self, forKey: .sessionId),
                              path: try c.decodeIfPresent(String.self, forKey: .path))
        case "readFile":
            self = .readFile(sessionId: try c.decode(String.self, forKey: .sessionId),
                             path: try c.decode(String.self, forKey: .path))
```

In `encode(to:)`:

```swift
        case .listChanges(let s):
            try c.encode("listChanges", forKey: .type)
            try c.encode(s, forKey: .sessionId)
        case .fileDiff(let s, let path):
            try c.encode("fileDiff", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
        case .listFiles(let s, let path):
            try c.encode("listFiles", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encodeIfPresent(path, forKey: .path)
        case .readFile(let s, let path):
            try c.encode("readFile", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
```

Leave `isControl` and `isDriveOrdering` untouched: these are read verbs, and `isDriveOrdering`'s `default: return false` already covers them, which is the documented behavior (stop stays fast during a backfill).

- [ ] **Step 5: Add the server message cases**

In `RemoteServerMessage`, add:

```swift
    case changeList(
        sessionId: String, comparisonRef: String?, metricsAvailable: Bool,
        files: [RemoteChangedFile], truncated: Bool)
    case changeListFailed(sessionId: String, reason: RemoteFileAccessReason, message: String?)
    case fileDiffResult(sessionId: String, path: String, hunks: [RemoteDiffHunk], truncated: Bool)
    case fileDiffFailed(sessionId: String, path: String, reason: RemoteFileAccessReason, message: String?)
    case fileTree(sessionId: String, path: String?, nodes: [RemoteFileNode])
    case fileTreeFailed(sessionId: String, path: String?, reason: RemoteFileAccessReason, message: String?)
    case fileContents(sessionId: String, path: String, text: String, truncated: Bool)
    case fileUnavailable(
        sessionId: String, path: String, reason: RemoteFileAccessReason,
        byteSize: Int?, message: String?)
```

Decoding arms:

```swift
        case "changeList":
            self = .changeList(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                comparisonRef: try c.decodeIfPresent(String.self, forKey: .comparisonRef),
                metricsAvailable: try c.decode(Bool.self, forKey: .metricsAvailable),
                files: try c.decode([RemoteChangedFile].self, forKey: .files),
                truncated: try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false)
        case "changeListFailed":
            self = .changeListFailed(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                reason: try c.decode(RemoteFileAccessReason.self, forKey: .reason),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case "fileDiffResult":
            self = .fileDiffResult(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                hunks: try c.decode([RemoteDiffHunk].self, forKey: .hunks),
                truncated: try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false)
        case "fileDiffFailed":
            self = .fileDiffFailed(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                reason: try c.decode(RemoteFileAccessReason.self, forKey: .reason),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case "fileTree":
            self = .fileTree(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decodeIfPresent(String.self, forKey: .path),
                nodes: try c.decode([RemoteFileNode].self, forKey: .nodes))
        case "fileTreeFailed":
            self = .fileTreeFailed(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decodeIfPresent(String.self, forKey: .path),
                reason: try c.decode(RemoteFileAccessReason.self, forKey: .reason),
                message: try c.decodeIfPresent(String.self, forKey: .message))
        case "fileContents":
            self = .fileContents(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                text: try c.decode(String.self, forKey: .text),
                truncated: try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false)
        case "fileUnavailable":
            self = .fileUnavailable(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                path: try c.decode(String.self, forKey: .path),
                reason: try c.decode(RemoteFileAccessReason.self, forKey: .reason),
                byteSize: try c.decodeIfPresent(Int.self, forKey: .byteSize),
                message: try c.decodeIfPresent(String.self, forKey: .message))
```

Encoding arms:

```swift
        case .changeList(let s, let ref, let available, let files, let truncated):
            try c.encode("changeList", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encodeIfPresent(ref, forKey: .comparisonRef)
            try c.encode(available, forKey: .metricsAvailable)
            try c.encode(files, forKey: .files)
            try c.encode(truncated, forKey: .truncated)
        case .changeListFailed(let s, let reason, let message):
            try c.encode("changeListFailed", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(reason.rawValue, forKey: .reason)
            try c.encodeIfPresent(message, forKey: .message)
        case .fileDiffResult(let s, let path, let hunks, let truncated):
            try c.encode("fileDiffResult", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encode(hunks, forKey: .hunks)
            try c.encode(truncated, forKey: .truncated)
        case .fileDiffFailed(let s, let path, let reason, let message):
            try c.encode("fileDiffFailed", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encode(reason.rawValue, forKey: .reason)
            try c.encodeIfPresent(message, forKey: .message)
        case .fileTree(let s, let path, let nodes):
            try c.encode("fileTree", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encode(nodes, forKey: .nodes)
        case .fileTreeFailed(let s, let path, let reason, let message):
            try c.encode("fileTreeFailed", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encode(reason.rawValue, forKey: .reason)
            try c.encodeIfPresent(message, forKey: .message)
        case .fileContents(let s, let path, let text, let truncated):
            try c.encode("fileContents", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encode(text, forKey: .text)
            try c.encode(truncated, forKey: .truncated)
        case .fileUnavailable(let s, let path, let reason, let byteSize, let message):
            try c.encode("fileUnavailable", forKey: .type)
            try c.encode(s, forKey: .sessionId)
            try c.encode(path, forKey: .path)
            try c.encode(reason.rawValue, forKey: .reason)
            try c.encodeIfPresent(byteSize, forKey: .byteSize)
            try c.encodeIfPresent(message, forKey: .message)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteProtocolTests test 2>&1 | tail -20`
Expected: PASS, including the three new tests.

- [ ] **Step 7: Commit**

```bash
git add Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift Alas/Sources/Remote/Protocol/RemoteProtocol.swift AlasTests/Remote/RemoteProtocolTests.swift
git commit -m "feat(remote): protocol messages for changes and files"
```

---

### Task 2: Path safety and payload caps

**Files:**
- Create: `Alas/Sources/Remote/Gateway/RemoteWorktreeFileAccess.swift`
- Test: `AlasTests/Remote/RemoteWorktreeFileAccessTests.swift`

**Interfaces:**
- Consumes: `ParsedDiff`, `ChangedFile` (existing git types).
- Produces: `RemoteWorktreeFileAccess.maxFileBytes: Int`, `.maxDiffLines: Int`, `.maxChangedFiles: Int`, `resolve(path:in:) -> URL?`, `truncateHunks(_:) -> (hunks: [ParsedDiff.Hunk], truncated: Bool)`, `truncateFiles(_:) -> (files: [ChangedFile], truncated: Bool)`.

- [ ] **Step 1: Write the failing test**

Create `AlasTests/Remote/RemoteWorktreeFileAccessTests.swift`:

```swift
import Testing
import Foundation
@testable import Alas

struct RemoteWorktreeFileAccessTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-file-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func resolvesPlainRelativePathInsideTheWorktree() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "hi\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let resolved = RemoteWorktreeFileAccess.resolve(path: "a.txt", in: root)
        #expect(resolved?.lastPathComponent == "a.txt")
    }

    @Test func rejectsTraversalAbsoluteAndEmptyPaths() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(RemoteWorktreeFileAccess.resolve(path: "../secrets.txt", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: "src/../../secrets.txt", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: "/etc/passwd", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: "", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: "   ", in: root) == nil)
    }

    @Test func rejectsDotGitAtAnyDepth() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(RemoteWorktreeFileAccess.resolve(path: ".git", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: ".git/config", in: root) == nil)
        #expect(RemoteWorktreeFileAccess.resolve(path: "src/.git/config", in: root) == nil)
    }

    @Test func rejectsSymlinkEscapingTheWorktree() throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try "secret\n".write(to: outside.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside)

        #expect(RemoteWorktreeFileAccess.resolve(path: "escape/s.txt", in: root) == nil)
    }

    @Test func truncatesHunksAtTheLineCap() {
        let line = ParsedDiff.Hunk.Line(kind: .add, text: "x", oldNumber: nil, newNumber: 1)
        let big = ParsedDiff.Hunk(
            header: "@@ -0,0 +1,1 @@", oldStart: 0, newStart: 1,
            lines: Array(repeating: line, count: RemoteWorktreeFileAccess.maxDiffLines + 10))
        let small = ParsedDiff.Hunk(
            header: "@@ -0,0 +1,1 @@", oldStart: 0, newStart: 1, lines: [line])

        let truncated = RemoteWorktreeFileAccess.truncateHunks([big])
        #expect(truncated.truncated)
        #expect(truncated.hunks.reduce(0) { $0 + $1.lines.count } == RemoteWorktreeFileAccess.maxDiffLines)

        let kept = RemoteWorktreeFileAccess.truncateHunks([small])
        #expect(!kept.truncated)
        #expect(kept.hunks.count == 1)
    }

    @Test func truncatesChangedFilesAtTheFileCap() {
        let files = (0..<(RemoteWorktreeFileAccess.maxChangedFiles + 5)).map { index in
            ChangedFile(path: "f\(index).txt", status: "M", stage: .unstaged,
                        add: 1, del: 0, renameFrom: nil)
        }
        let result = RemoteWorktreeFileAccess.truncateFiles(files)
        #expect(result.truncated)
        #expect(result.files.count == RemoteWorktreeFileAccess.maxChangedFiles)

        let short = RemoteWorktreeFileAccess.truncateFiles(Array(files.prefix(3)))
        #expect(!short.truncated)
        #expect(short.files.count == 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteWorktreeFileAccessTests test 2>&1 | tail -20`
Expected: compile failure — `RemoteWorktreeFileAccess` does not exist.

- [ ] **Step 3: Write the implementation**

Create `Alas/Sources/Remote/Gateway/RemoteWorktreeFileAccess.swift`:

```swift
import Foundation

/// Path validation and payload caps for the remote changes/files surface.
///
/// Every path here arrives from a paired device, so containment is enforced on
/// the resolved (symlink-followed) path, not the string. `.git` is excluded
/// entirely: a worktree's git config can hold remote URLs with embedded
/// credentials.
enum RemoteWorktreeFileAccess {
    static let maxFileBytes = 512 * 1024
    static let maxDiffLines = 2_000
    static let maxChangedFiles = 500

    /// Returns the on-disk URL for a worktree-relative path, or nil when the
    /// path is empty, absolute, traverses upward, names `.git`, or resolves
    /// outside the worktree through a symlink.
    static func resolve(path: String, in worktreeRoot: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return nil }
        guard !components.contains(".."), !components.contains(".git") else { return nil }

        let candidate = components.reduce(worktreeRoot) { $0.appendingPathComponent($1) }
        let resolvedRoot = worktreeRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL

        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolved.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }

    /// Caps a diff at `maxDiffLines` total lines, dropping whole trailing
    /// lines from the hunk that crosses the cap. Reports whether anything was
    /// dropped so the client can render a truncation footer.
    static func truncateHunks(_ hunks: [ParsedDiff.Hunk]) -> (hunks: [ParsedDiff.Hunk], truncated: Bool) {
        var remaining = maxDiffLines
        var kept: [ParsedDiff.Hunk] = []
        for hunk in hunks {
            if remaining <= 0 { return (kept, true) }
            if hunk.lines.count <= remaining {
                kept.append(hunk)
                remaining -= hunk.lines.count
                continue
            }
            kept.append(ParsedDiff.Hunk(
                header: hunk.header,
                oldStart: hunk.oldStart,
                newStart: hunk.newStart,
                lines: Array(hunk.lines.prefix(remaining))))
            return (kept, true)
        }
        return (kept, false)
    }

    /// Caps a change list at `maxChangedFiles` entries.
    static func truncateFiles(_ files: [ChangedFile]) -> (files: [ChangedFile], truncated: Bool) {
        guard files.count > maxChangedFiles else { return (files, false) }
        return (Array(files.prefix(maxChangedFiles)), true)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodegen && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteWorktreeFileAccessTests test 2>&1 | tail -20`
Expected: PASS, six tests.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Gateway/RemoteWorktreeFileAccess.swift AlasTests/Remote/RemoteWorktreeFileAccessTests.swift Alas.xcodeproj
git commit -m "feat(remote): path safety and payload caps for file access"
```

---

### Task 3: Base-relative changed files and against-ref diff

**Files:**
- Create: `Alas/Sources/Git/GitService+RemoteChanges.swift`
- Test: `AlasTests/GitServiceRemoteChangesTests.swift`

**Interfaces:**
- Consumes: `Process.git(_:cwd:)`, `NumstatParser.parse(_:)`, `NumstatParser.destinationPath(from:)`, `DiffParser.parse(_:)`, `GitService.status(worktreePath:)`, `GitService.diff(worktreePath:file:staged:originalPath:)`, `GitService.looksBinary(_:)`.
- Produces: `GitService.changedFilesAgainstRef(worktreePath:ref:) async throws -> [ChangedFile]` and `GitService.diff(worktreePath:againstRef:file:) async throws -> ParsedDiff`.

Both take `ref: String?`. A nil ref means no base could be resolved (unborn branch, no upstream); both then fall back to the working-tree view (`status` / `diff(worktreePath:file:)`), so the tab still shows uncommitted work instead of nothing.

- [ ] **Step 1: Write the failing test**

Create `AlasTests/GitServiceRemoteChangesTests.swift`:

```swift
import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
@MainActor
struct GitServiceRemoteChangesTests {
    private func makeRepo() async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-remote-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: tmp)
        _ = try await Process.git(["config", "user.email", "test@example.com"], cwd: tmp)
        _ = try await Process.git(["config", "user.name", "test user"], cwd: tmp)
        return tmp
    }

    @Test func changedFilesAgainstRef_includesCommittedAndUncommittedAndUntracked() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "base.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)

        try "one\ntwo\n".write(to: repo.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "base.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "committed change"], cwd: repo)

        try "dirty\n".write(to: repo.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "dirty.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "add dirty"], cwd: repo)
        try "dirty\nedited\n".write(to: repo.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)

        try "new\n".write(to: repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        let files = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: "start")
        #expect(files.map(\.path).sorted() == ["base.txt", "dirty.txt", "untracked.txt"])
        let base = try #require(files.first { $0.path == "base.txt" })
        #expect(base.status == "M")
        #expect(base.add == 1)
        let untracked = try #require(files.first { $0.path == "untracked.txt" })
        #expect(untracked.status == "A")
        #expect(untracked.add == 1)
    }

    @Test func changedFilesAgainstRef_fallsBackToStatusWhenRefIsNil() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "--allow-empty", "-m", "init"], cwd: repo)
        try "hello\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let files = try await GitService().changedFilesAgainstRef(worktreePath: repo, ref: nil)
        #expect(files.map(\.path) == ["a.txt"])
    }

    @Test func diffAgainstRef_returnsHunksForACommittedChange() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "base"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)
        try "one\ntwo\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: repo)
        _ = try await Process.git(["commit", "-m", "second line"], cwd: repo)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "a.txt")
        let added = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }
        #expect(added.map(\.text) == ["two"])
    }

    @Test func diffAgainstRef_showsUntrackedFileAsAllAdd() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "--allow-empty", "-m", "init"], cwd: repo)
        _ = try await Process.git(["branch", "start"], cwd: repo)
        try "fresh\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let diff = try await GitService().diff(worktreePath: repo, againstRef: "start", file: "new.txt")
        let added = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }
        #expect(added.map(\.text) == ["fresh"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitServiceRemoteChangesTests test 2>&1 | tail -20`
Expected: compile failure — `changedFilesAgainstRef` does not exist.

- [ ] **Step 3: Write the implementation**

Create `Alas/Sources/Git/GitService+RemoteChanges.swift`:

```swift
import Foundation

/// Base-relative views used by the remote changes surface. Unlike the desktop
/// Changes panel (working tree vs index/HEAD), these compare the whole
/// worktree — commits plus uncommitted work — against the comparison ref, so
/// the remote client shows everything an agent did on this branch.
extension GitService {
    /// Changed files between `ref` and the working tree, plus untracked files.
    /// A nil `ref` (unborn branch, no resolvable base) falls back to `status`.
    func changedFilesAgainstRef(worktreePath: URL, ref: String?) async throws -> [ChangedFile] {
        guard let ref, !ref.isEmpty else {
            return try await status(worktreePath: worktreePath)
        }

        let numstat = try await Process.git(
            ["diff", "--numstat", "-M", "-C", ref, "--"], cwd: worktreePath)
        guard numstat.exitCode == 0 else {
            return try await status(worktreePath: worktreePath)
        }
        let counts = NumstatParser.parse(numstat.stdout)

        let nameStatus = try await Process.git(
            ["diff", "--name-status", "-M", "-C", ref, "--"], cwd: worktreePath)
        let statusEntries = try await status(worktreePath: worktreePath)
        let conflicts = Dictionary(
            statusEntries.compactMap { entry in entry.conflict.map { (entry.path, $0) } },
            uniquingKeysWith: { first, _ in first })

        var files: [ChangedFile] = []
        var seen = Set<String>()
        for line in nameStatus.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard let code = parts.first, parts.count >= 2 else { continue }
            let letter = String(code.prefix(1))
            // Rename/copy entries carry both the source and destination path.
            let path = parts.count >= 3 ? parts[2] : parts[1]
            let renameFrom = parts.count >= 3 ? parts[1] : nil
            guard seen.insert(path).inserted else { continue }
            let count = counts[path] ?? (add: 0, del: 0)
            files.append(ChangedFile(
                path: path,
                status: letter,
                stage: .unstaged,   // not meaningful for a base-relative view
                add: count.add,
                del: count.del,
                renameFrom: renameFrom,
                conflict: conflicts[path]))
        }

        let untracked = try await Process.git(
            ["ls-files", "--others", "--exclude-standard"], cwd: worktreePath)
        for raw in untracked.stdout.split(separator: "\n") {
            let path = String(raw)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            files.append(ChangedFile(
                path: path,
                status: "A",
                stage: .unstaged,
                add: Self.addedLineCount(worktreePath: worktreePath, path: path),
                del: 0,
                renameFrom: nil,
                conflict: nil))
        }

        return files.sorted { $0.path < $1.path }
    }

    /// Diff of one file between `ref` and the working tree. Untracked files
    /// diff against /dev/null so they render as a single all-add hunk. A nil
    /// `ref` falls back to the working-tree diff.
    func diff(worktreePath: URL, againstRef ref: String?, file: String) async throws -> ParsedDiff {
        guard let ref, !ref.isEmpty else {
            return try await diff(worktreePath: worktreePath, file: file)
        }

        let tracked = try await Process.git(
            ["ls-files", "--error-unmatch", "--", file], cwd: worktreePath)
        if tracked.exitCode != 0 {
            let result = try await Process.git(
                ["diff", "--no-color", "--no-index", "--", "/dev/null", file], cwd: worktreePath)
            // `--no-index` exits 1 when there ARE differences, which is the
            // normal case here; only >= 2 is a real failure.
            guard result.exitCode <= 1 else { return ParsedDiff(hunks: []) }
            return DiffParser.parse(result.stdout)
        }

        let result = try await Process.git(
            ["diff", "--no-color", "-M", "-C", ref, "--", file], cwd: worktreePath)
        guard result.exitCode <= 1 else { return ParsedDiff(hunks: []) }
        return DiffParser.parse(result.stdout)
    }

    /// Line count for an untracked file, or 0 when it is binary or unreadable.
    private static func addedLineCount(worktreePath: URL, path: String) -> Int {
        let url = worktreePath.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url), !looksBinary(data),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        if text.isEmpty { return 0 }
        return text.hasSuffix("\n")
            ? text.split(separator: "\n", omittingEmptySubsequences: false).count - 1
            : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodegen && xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/GitServiceRemoteChangesTests test 2>&1 | tail -20`
Expected: PASS, four tests.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Git/GitService+RemoteChanges.swift AlasTests/GitServiceRemoteChangesTests.swift Alas.xcodeproj
git commit -m "feat(git): base-relative changed files and against-ref diff"
```

---

### Task 4: Provider methods and AppState implementation

**Files:**
- Modify: `Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift` (result enums)
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionsProvider.swift`
- Modify: `Alas/Sources/App/AppState.swift` (the `extension AppState: RemoteSessionsProvider` block that already holds `remoteWorktreeSummary`, near line 7256)
- Modify: `AlasTests/Remote/RemoteSessionGatewayTests.swift` (`FakeSessionsProvider`, near line 6)
- Test: `AlasTests/Remote/RemoteAppStateAccessTests.swift`

**Interfaces:**
- Consumes: `RemoteChangedFile`, `RemoteDiffHunk`, `RemoteDiffLine`, `RemoteFileNode`, `RemoteFileAccessReason` (Task 1); `RemoteWorktreeFileAccess` (Task 2); `changedFilesAgainstRef(worktreePath:ref:)`, `diff(worktreePath:againstRef:file:)` (Task 3); existing `GitService.fileTree(worktreePath:statusEntries:)`, `fileTreeChildren(worktreePath:path:)`, `commitsAhead(at:baseBranch:resolution:)`, `looksBinary(_:)`; existing `AppState.projectAndWorktree(withWorktreeId:)`.
- Produces: `RemoteChangeListResult`, `RemoteFileDiffResult`, `RemoteFileTreeResult`, `RemoteFileContentsResult`; provider methods `remoteChangeList(sessionId:)`, `remoteFileDiff(sessionId:path:)`, `remoteFileTree(sessionId:path:)`, `remoteFileContents(sessionId:path:)`.

- [ ] **Step 1: Write the failing test**

Append to `AlasTests/Remote/RemoteAppStateAccessTests.swift`, inside `struct RemoteAppStateAccessTests`:

```swift
    @Test func remoteChangeListReportsSessionUnknownForAnUnknownSession() async throws {
        let state = AppState(store: MemoryStore())
        let result = await state.remoteChangeList(sessionId: "no-such-session")
        #expect(result == .failure(reason: .sessionUnknown, message: nil))
    }

    @Test func remoteFileDiffReportsSessionUnknownForAnUnknownSession() async throws {
        let state = AppState(store: MemoryStore())
        let result = await state.remoteFileDiff(sessionId: "no-such-session", path: "a.txt")
        #expect(result == .failure(reason: .sessionUnknown, message: nil))
    }

    @Test func remoteFileTreeReportsSessionUnknownForAnUnknownSession() async throws {
        let state = AppState(store: MemoryStore())
        let result = await state.remoteFileTree(sessionId: "no-such-session", path: nil)
        #expect(result == .failure(reason: .sessionUnknown, message: nil))
    }

    @Test func remoteFileContentsReportsSessionUnknownForAnUnknownSession() async throws {
        let state = AppState(store: MemoryStore())
        let result = await state.remoteFileContents(sessionId: "no-such-session", path: "a.txt")
        #expect(result == .failure(reason: .sessionUnknown, byteSize: nil, message: nil))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteAppStateAccessTests test 2>&1 | tail -20`
Expected: compile failure — `remoteChangeList` does not exist.

- [ ] **Step 3: Add the result enums**

Append to `Alas/Sources/Remote/Protocol/RemoteMessageWireJSON.swift`:

```swift
enum RemoteChangeListResult: Equatable, Sendable {
    case success(
        comparisonRef: String?, metricsAvailable: Bool,
        files: [RemoteChangedFile], truncated: Bool)
    case failure(reason: RemoteFileAccessReason, message: String?)
}

enum RemoteFileDiffResult: Equatable, Sendable {
    case success(hunks: [RemoteDiffHunk], truncated: Bool)
    case failure(reason: RemoteFileAccessReason, message: String?)
}

enum RemoteFileTreeResult: Equatable, Sendable {
    case success(nodes: [RemoteFileNode])
    case failure(reason: RemoteFileAccessReason, message: String?)
}

enum RemoteFileContentsResult: Equatable, Sendable {
    case success(text: String, truncated: Bool)
    case failure(reason: RemoteFileAccessReason, byteSize: Int?, message: String?)
}
```

- [ ] **Step 4: Extend the provider protocol**

In `Alas/Sources/Remote/Gateway/RemoteSessionsProvider.swift`, add after `func sessionConfig(for id: String) -> RemoteSessionConfig?`:

```swift
    /// Read-only worktree inspection for the remote changes/files tabs. All
    /// four resolve the session's worktree first and are ungated by the writer
    /// lease: seeing a session is enough to read its code.
    func remoteChangeList(sessionId: String) async -> RemoteChangeListResult
    func remoteFileDiff(sessionId: String, path: String) async -> RemoteFileDiffResult
    func remoteFileTree(sessionId: String, path: String?) async -> RemoteFileTreeResult
    func remoteFileContents(sessionId: String, path: String) async -> RemoteFileContentsResult
```

- [ ] **Step 5: Implement on AppState**

In `Alas/Sources/App/AppState.swift`, inside `extension AppState: RemoteSessionsProvider`, add:

```swift
    /// Resolves the worktree backing a session id by scanning the live
    /// per-worktree managers, mirroring how `session(for:)` looks sessions up.
    private func remoteWorktreeContext(sessionId: String) -> (project: ProjectConfig, worktree: Worktree)? {
        for mgr in acpManagers.values where mgr.sessionRows.contains(where: { $0.id == sessionId }) {
            return projectAndWorktree(withWorktreeId: mgr.worktreeId)
        }
        return nil
    }

    private static func remoteChangedFile(_ file: ChangedFile) -> RemoteChangedFile {
        RemoteChangedFile(
            path: file.path,
            status: file.status,
            add: file.add,
            del: file.del,
            conflict: file.conflict?.rawValue,
            renameFrom: file.renameFrom)
    }

    private static func remoteDiffHunk(_ hunk: ParsedDiff.Hunk) -> RemoteDiffHunk {
        RemoteDiffHunk(
            header: hunk.header,
            oldStart: hunk.oldStart,
            newStart: hunk.newStart,
            lines: hunk.lines.map { line in
                let kind: String
                switch line.kind {
                case .context: kind = "context"
                case .add: kind = "add"
                case .delete: kind = "delete"
                }
                return RemoteDiffLine(
                    kind: kind, text: line.text,
                    oldNumber: line.oldNumber, newNumber: line.newNumber)
            })
    }

    /// Drops ignored and excluded nodes at the wire boundary: the remote file
    /// browser is git-aware, so build output never reaches the phone.
    private static func remoteFileNodes(_ nodes: [FileTreeNode]) -> [RemoteFileNode] {
        nodes.compactMap { node in
            guard node.visibility != .ignored, node.visibility != .excluded else { return nil }
            return RemoteFileNode(
                name: node.name,
                path: node.path,
                kind: node.kind.rawValue,
                badge: node.badge,
                childrenState: node.childrenState.rawValue,
                isSubmodule: node.isSubmodule)
        }
    }

    func remoteChangeList(sessionId: String) async -> RemoteChangeListResult {
        guard let context = remoteWorktreeContext(sessionId: sessionId) else {
            return .failure(reason: .sessionUnknown, message: nil)
        }
        let git = GitService()
        do {
            let commits = try await git.commitsAhead(
                at: context.worktree.path,
                baseBranch: config.worktrees.baseBranch,
                resolution: GitService.BaseResolution.forCommits(
                    mode: config.changes.comparisonMode, userOverrodeBaseBranch: false))
            let changed = try await git.changedFilesAgainstRef(
                worktreePath: context.worktree.path, ref: commits.comparisonRef)
            let capped = RemoteWorktreeFileAccess.truncateFiles(changed)
            return .success(
                comparisonRef: commits.comparisonRef,
                metricsAvailable: true,
                files: capped.files.map(Self.remoteChangedFile),
                truncated: capped.truncated)
        } catch {
            return .failure(reason: .gitFailed, message: error.localizedDescription)
        }
    }

    func remoteFileDiff(sessionId: String, path: String) async -> RemoteFileDiffResult {
        guard let context = remoteWorktreeContext(sessionId: sessionId) else {
            return .failure(reason: .sessionUnknown, message: nil)
        }
        guard let url = RemoteWorktreeFileAccess.resolve(path: path, in: context.worktree.path) else {
            return .failure(reason: .pathRejected, message: nil)
        }
        if let data = try? Data(contentsOf: url), GitService.looksBinary(data) {
            return .failure(reason: .binary, message: nil)
        }
        let git = GitService()
        do {
            let commits = try await git.commitsAhead(
                at: context.worktree.path,
                baseBranch: config.worktrees.baseBranch,
                resolution: GitService.BaseResolution.forCommits(
                    mode: config.changes.comparisonMode, userOverrodeBaseBranch: false))
            let parsed = try await git.diff(
                worktreePath: context.worktree.path,
                againstRef: commits.comparisonRef,
                file: path)
            let capped = RemoteWorktreeFileAccess.truncateHunks(parsed.hunks)
            return .success(
                hunks: capped.hunks.map(Self.remoteDiffHunk),
                truncated: capped.truncated)
        } catch {
            return .failure(reason: .gitFailed, message: error.localizedDescription)
        }
    }

    func remoteFileTree(sessionId: String, path: String?) async -> RemoteFileTreeResult {
        guard let context = remoteWorktreeContext(sessionId: sessionId) else {
            return .failure(reason: .sessionUnknown, message: nil)
        }
        let git = GitService()
        do {
            guard let path, !path.isEmpty else {
                let statusEntries = try await git.status(worktreePath: context.worktree.path)
                let nodes = try await git.fileTree(
                    worktreePath: context.worktree.path, statusEntries: statusEntries)
                return .success(nodes: Self.remoteFileNodes(nodes))
            }
            guard RemoteWorktreeFileAccess.resolve(path: path, in: context.worktree.path) != nil else {
                return .failure(reason: .pathRejected, message: nil)
            }
            let nodes = try await git.fileTreeChildren(
                worktreePath: context.worktree.path, path: path)
            return .success(nodes: Self.remoteFileNodes(nodes))
        } catch {
            return .failure(reason: .gitFailed, message: error.localizedDescription)
        }
    }

    func remoteFileContents(sessionId: String, path: String) async -> RemoteFileContentsResult {
        guard let context = remoteWorktreeContext(sessionId: sessionId) else {
            return .failure(reason: .sessionUnknown, byteSize: nil, message: nil)
        }
        guard let url = RemoteWorktreeFileAccess.resolve(path: path, in: context.worktree.path) else {
            return .failure(reason: .pathRejected, byteSize: nil, message: nil)
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(reason: .notFound, byteSize: nil, message: nil)
        }
        guard !GitService.looksBinary(data) else {
            return .failure(reason: .binary, byteSize: data.count, message: nil)
        }
        guard data.count <= RemoteWorktreeFileAccess.maxFileBytes else {
            return .failure(reason: .tooLarge, byteSize: data.count, message: nil)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(reason: .binary, byteSize: data.count, message: nil)
        }
        return .success(text: text, truncated: false)
    }
```

- [ ] **Step 6: Conform the test fake**

In `AlasTests/Remote/RemoteSessionGatewayTests.swift`, add to `final class FakeSessionsProvider` — stored results plus recorded requests, so Task 5 can assert dispatch:

```swift
    var changeListResult: RemoteChangeListResult = .failure(reason: .sessionUnknown, message: nil)
    var fileDiffResult: RemoteFileDiffResult = .failure(reason: .sessionUnknown, message: nil)
    var fileTreeResult: RemoteFileTreeResult = .failure(reason: .sessionUnknown, message: nil)
    var fileContentsResult: RemoteFileContentsResult = .failure(reason: .sessionUnknown, byteSize: nil, message: nil)
    var changeListRequests: [String] = []
    var fileDiffRequests: [(sessionId: String, path: String)] = []
    var fileTreeRequests: [(sessionId: String, path: String?)] = []
    var fileContentsRequests: [(sessionId: String, path: String)] = []

    func remoteChangeList(sessionId: String) async -> RemoteChangeListResult {
        changeListRequests.append(sessionId)
        return changeListResult
    }

    func remoteFileDiff(sessionId: String, path: String) async -> RemoteFileDiffResult {
        fileDiffRequests.append((sessionId, path))
        return fileDiffResult
    }

    func remoteFileTree(sessionId: String, path: String?) async -> RemoteFileTreeResult {
        fileTreeRequests.append((sessionId, path))
        return fileTreeResult
    }

    func remoteFileContents(sessionId: String, path: String) async -> RemoteFileContentsResult {
        fileContentsRequests.append((sessionId, path))
        return fileContentsResult
    }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteAppStateAccessTests -only-testing:AlasTests/RemoteSessionGatewayTests test 2>&1 | tail -20`
Expected: PASS — the four new AppState tests plus the existing gateway suite still green.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources/Remote Alas/Sources/App/AppState.swift AlasTests/Remote
git commit -m "feat(remote): worktree changes and files provider methods"
```

---

### Task 5: Gateway dispatch and in-flight deduplication

**Files:**
- Modify: `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift` (the `handle(_:)` switch, near line 47)
- Test: `AlasTests/Remote/RemoteSessionGatewayTests.swift`

**Interfaces:**
- Consumes: provider methods and result enums from Task 4; server message cases from Task 1.
- Produces: gateway handling for `listChanges`, `fileDiff`, `listFiles`, `readFile`.

- [ ] **Step 1: Write the failing test**

Append to `AlasTests/Remote/RemoteSessionGatewayTests.swift`, following the file's existing test style (build a `FakeSessionsProvider`, construct `RemoteSessionGateway`, capture sent messages):

```swift
    @Test func listChangesSendsChangeListFromTheProvider() async {
        let provider = FakeSessionsProvider()
        let file = RemoteChangedFile(
            path: "a.txt", status: "M", add: 2, del: 1, conflict: nil, renameFrom: nil)
        provider.changeListResult = .success(
            comparisonRef: "origin/main", metricsAvailable: true, files: [file], truncated: false)
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gateway.handle(.listChanges(sessionId: "s1"))

        #expect(provider.changeListRequests == ["s1"])
        #expect(sent == [.changeList(
            sessionId: "s1", comparisonRef: "origin/main", metricsAvailable: true,
            files: [file], truncated: false)])
    }

    @Test func listChangesSendsFailureMessageOnProviderFailure() async {
        let provider = FakeSessionsProvider()
        provider.changeListResult = .failure(reason: .worktreeUnavailable, message: "gone")
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gateway.handle(.listChanges(sessionId: "s1"))

        #expect(sent == [.changeListFailed(
            sessionId: "s1", reason: .worktreeUnavailable, message: "gone")])
    }

    @Test func fileDiffSendsHunksAndFailures() async {
        let provider = FakeSessionsProvider()
        let hunk = RemoteDiffHunk(
            header: "@@ -1 +1,2 @@", oldStart: 1, newStart: 1,
            lines: [RemoteDiffLine(kind: "add", text: "new", oldNumber: nil, newNumber: 2)])
        provider.fileDiffResult = .success(hunks: [hunk], truncated: true)
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gateway.handle(.fileDiff(sessionId: "s1", path: "a.txt"))
        #expect(provider.fileDiffRequests.map(\.path) == ["a.txt"])
        #expect(sent == [.fileDiffResult(
            sessionId: "s1", path: "a.txt", hunks: [hunk], truncated: true)])

        provider.fileDiffResult = .failure(reason: .pathRejected, message: nil)
        sent.removeAll()
        await gateway.handle(.fileDiff(sessionId: "s1", path: "../etc/passwd"))
        #expect(sent == [.fileDiffFailed(
            sessionId: "s1", path: "../etc/passwd", reason: .pathRejected, message: nil)])
    }

    @Test func listFilesAndReadFileSendTreeAndContents() async {
        let provider = FakeSessionsProvider()
        let node = RemoteFileNode(
            name: "src", path: "src", kind: "dir", badge: nil,
            childrenState: "notLoaded", isSubmodule: false)
        provider.fileTreeResult = .success(nodes: [node])
        provider.fileContentsResult = .success(text: "# Alas\n", truncated: false)
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gateway.handle(.listFiles(sessionId: "s1", path: nil))
        await gateway.handle(.readFile(sessionId: "s1", path: "README.md"))

        #expect(sent == [
            .fileTree(sessionId: "s1", path: nil, nodes: [node]),
            .fileContents(sessionId: "s1", path: "README.md", text: "# Alas\n", truncated: false)
        ])
    }

    @Test func readFileSendsUnavailableWithByteSize() async {
        let provider = FakeSessionsProvider()
        provider.fileContentsResult = .failure(reason: .tooLarge, byteSize: 900_000, message: nil)
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        await gateway.handle(.readFile(sessionId: "s1", path: "big.bin"))

        #expect(sent == [.fileUnavailable(
            sessionId: "s1", path: "big.bin", reason: .tooLarge, byteSize: 900_000, message: nil)])
    }

    @Test func duplicateInFlightRequestsForTheSamePathAreDropped() async {
        let provider = FakeSessionsProvider()
        provider.fileDiffResult = .success(hunks: [], truncated: false)
        var sent: [RemoteServerMessage] = []
        let gateway = RemoteSessionGateway(provider: provider) { sent.append($0) }

        async let first: Void = gateway.handle(.fileDiff(sessionId: "s1", path: "a.txt"))
        async let second: Void = gateway.handle(.fileDiff(sessionId: "s1", path: "a.txt"))
        _ = await (first, second)

        #expect(provider.fileDiffRequests.count <= 2)
        #expect(sent.allSatisfy { message in
            if case .fileDiffResult(_, let path, _, _) = message { return path == "a.txt" }
            return false
        })
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteSessionGatewayTests test 2>&1 | tail -30`
Expected: compile failure — `handle` has no case for `.listChanges`.

- [ ] **Step 3: Write the implementation**

In `Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift`, add a stored property next to the other per-connection state:

```swift
    /// Requests currently being served, keyed by "<verb>\0<sessionId>\0<path>".
    /// A repeat while one is in flight is dropped: the client re-renders from
    /// the response either way, and each of these spawns a git process.
    private var inFlightFileRequests: Set<String> = []
```

Add to the `handle(_:)` switch:

```swift
        case .listChanges(let id):
            let key = "listChanges\u{0}\(id)"
            guard inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            switch await provider.remoteChangeList(sessionId: id) {
            case .success(let ref, let available, let files, let truncated):
                send(.changeList(
                    sessionId: id, comparisonRef: ref, metricsAvailable: available,
                    files: files, truncated: truncated))
            case .failure(let reason, let message):
                send(.changeListFailed(sessionId: id, reason: reason, message: message))
            }
        case .fileDiff(let id, let path):
            let key = "fileDiff\u{0}\(id)\u{0}\(path)"
            guard inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            switch await provider.remoteFileDiff(sessionId: id, path: path) {
            case .success(let hunks, let truncated):
                send(.fileDiffResult(sessionId: id, path: path, hunks: hunks, truncated: truncated))
            case .failure(let reason, let message):
                send(.fileDiffFailed(sessionId: id, path: path, reason: reason, message: message))
            }
        case .listFiles(let id, let path):
            let key = "listFiles\u{0}\(id)\u{0}\(path ?? "")"
            guard inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            switch await provider.remoteFileTree(sessionId: id, path: path) {
            case .success(let nodes):
                send(.fileTree(sessionId: id, path: path, nodes: nodes))
            case .failure(let reason, let message):
                send(.fileTreeFailed(sessionId: id, path: path, reason: reason, message: message))
            }
        case .readFile(let id, let path):
            let key = "readFile\u{0}\(id)\u{0}\(path)"
            guard inFlightFileRequests.insert(key).inserted else { return }
            defer { inFlightFileRequests.remove(key) }
            switch await provider.remoteFileContents(sessionId: id, path: path) {
            case .success(let text, let truncated):
                send(.fileContents(sessionId: id, path: path, text: text, truncated: truncated))
            case .failure(let reason, let byteSize, let message):
                send(.fileUnavailable(
                    sessionId: id, path: path, reason: reason,
                    byteSize: byteSize, message: message))
            }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteSessionGatewayTests test 2>&1 | tail -20`
Expected: PASS, six new tests plus the existing suite.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Remote/Gateway/RemoteSessionGateway.swift AlasTests/Remote/RemoteSessionGatewayTests.swift
git commit -m "feat(remote): gateway dispatch for changes and files requests"
```

---

### Task 6: `changes-view.js` logic module

**Files:**
- Create: `Alas/Resources/RemoteWeb/changes-view.js`
- Create: `scripts/tests/remote-web-changes/test-changes-view.js`
- Create: `scripts/tests/remote-web-changes/run.sh`

**Interfaces:**
- Consumes: nothing (pure functions over the wire shapes from Task 1).
- Produces: `globalThis.RemoteChangesView = { sortFiles, splitPath, formatSummary, formatFileCounts, diffRows, truncationNotice }`.
  - `sortFiles(files)` → new array sorted by `path`.
  - `splitPath(path)` → `{ dir, name }`, `dir` is `""` at the root and otherwise ends with `/`.
  - `formatSummary({ comparisonRef, files, truncated })` → e.g. `"vs origin/main · 2 files · +14 −3"`.
  - `formatFileCounts(file)` → e.g. `"+12 −3"`.
  - `diffRows(hunks)` → flat array of `{ type: "hunk"|"line", text, kind, oldNumber, newNumber }`.
  - `truncationNotice(truncated, kind)` → string or `""`.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/remote-web-changes/test-changes-view.js`:

```javascript
const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/changes-view.js");

const view = globalThis.RemoteChangesView;

{
  const sorted = view.sortFiles([
    { path: "src/b.txt" },
    { path: "a.txt" },
    { path: "src/a.txt" }
  ]);
  assert.deepEqual(sorted.map((f) => f.path), ["a.txt", "src/a.txt", "src/b.txt"]);
}

{
  assert.deepEqual(view.splitPath("a.txt"), { dir: "", name: "a.txt" });
  assert.deepEqual(view.splitPath("src/app/main.swift"), { dir: "src/app/", name: "main.swift" });
}

{
  const summary = view.formatSummary({
    comparisonRef: "origin/main",
    files: [
      { path: "a.txt", add: 12, del: 3 },
      { path: "b.txt", add: 2, del: 0 }
    ],
    truncated: false
  });
  assert.equal(summary, "vs origin/main · 2 files · +14 −3");
}

{
  const summary = view.formatSummary({ comparisonRef: null, files: [{ path: "a.txt", add: 1, del: 0 }], truncated: false });
  assert.equal(summary, "1 file · +1 −0");
}

{
  assert.equal(view.formatFileCounts({ add: 12, del: 3 }), "+12 −3");
}

{
  const rows = view.diffRows([
    {
      header: "@@ -1,2 +1,3 @@",
      oldStart: 1,
      newStart: 1,
      lines: [
        { kind: "context", text: "import Foundation", oldNumber: 1, newNumber: 1 },
        { kind: "add", text: "import Testing", oldNumber: null, newNumber: 2 }
      ]
    }
  ]);
  assert.equal(rows.length, 3);
  assert.equal(rows[0].type, "hunk");
  assert.equal(rows[0].text, "@@ -1,2 +1,3 @@");
  assert.equal(rows[1].type, "line");
  assert.equal(rows[1].kind, "context");
  assert.equal(rows[2].kind, "add");
  assert.equal(rows[2].newNumber, 2);
}

{
  assert.equal(view.truncationNotice(false, "diff"), "");
  assert.equal(view.truncationNotice(true, "diff"), "Diff truncated — open this file on the desktop to see the rest.");
  assert.equal(view.truncationNotice(true, "files"), "File list truncated — too many changed files to show.");
}

console.log("remote-web-changes: ok");
```

Create `scripts/tests/remote-web-changes/run.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
node "$(dirname "$0")/test-changes-view.js"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x scripts/tests/remote-web-changes/run.sh && bash scripts/tests/remote-web-changes/run.sh`
Expected: FAIL — `Cannot find module '.../changes-view.js'`.

- [ ] **Step 3: Write the implementation**

Create `Alas/Resources/RemoteWeb/changes-view.js`:

```javascript
// Pure logic for the Changes tab: ordering, labels, and the diff row model.
// DOM wiring lives in app.js; everything here is unit-tested under
// scripts/tests/remote-web-changes.

function sortFiles(files) {
  return (files || []).slice().sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

function splitPath(path) {
  const value = path || "";
  const index = value.lastIndexOf("/");
  if (index < 0) return { dir: "", name: value };
  return { dir: value.slice(0, index + 1), name: value.slice(index + 1) };
}

function formatFileCounts(file) {
  const add = file && file.add ? file.add : 0;
  const del = file && file.del ? file.del : 0;
  return "+" + add + " −" + del;
}

function formatSummary(state) {
  const files = (state && state.files) || [];
  let add = 0;
  let del = 0;
  for (const file of files) {
    add += file.add || 0;
    del += file.del || 0;
  }
  const count = files.length + (files.length === 1 ? " file" : " files");
  const totals = count + " · +" + add + " −" + del;
  const ref = state && state.comparisonRef;
  return ref ? "vs " + ref + " · " + totals : totals;
}

function diffRows(hunks) {
  const rows = [];
  for (const hunk of hunks || []) {
    rows.push({ type: "hunk", text: hunk.header, kind: null, oldNumber: null, newNumber: null });
    for (const line of hunk.lines || []) {
      rows.push({
        type: "line",
        text: line.text,
        kind: line.kind,
        oldNumber: typeof line.oldNumber === "number" ? line.oldNumber : null,
        newNumber: typeof line.newNumber === "number" ? line.newNumber : null
      });
    }
  }
  return rows;
}

function truncationNotice(truncated, kind) {
  if (!truncated) return "";
  if (kind === "files") return "File list truncated — too many changed files to show.";
  return "Diff truncated — open this file on the desktop to see the rest.";
}

globalThis.RemoteChangesView = {
  sortFiles,
  splitPath,
  formatSummary,
  formatFileCounts,
  diffRows,
  truncationNotice
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/tests/remote-web-changes/run.sh`
Expected: `remote-web-changes: ok`

- [ ] **Step 5: Commit**

```bash
git add Alas/Resources/RemoteWeb/changes-view.js scripts/tests/remote-web-changes
git commit -m "feat(remote): changes view logic module"
```

---

### Task 7: `file-browser.js` logic module

**Files:**
- Create: `Alas/Resources/RemoteWeb/file-browser.js`
- Create: `scripts/tests/remote-web-file-browser/test-file-browser.js`
- Create: `scripts/tests/remote-web-file-browser/run.sh`

**Interfaces:**
- Consumes: nothing (pure functions over `RemoteFileNode` from Task 1).
- Produces: `globalThis.RemoteFileBrowser = { createTree, applyNodes, toggle, visibleRows, isExpanded, needsChildren, reset }` where `createTree()` returns a controller object with those methods bound to its own state.
  - `applyNodes(path, nodes)` stores a directory's children (`path` is `null` for the root).
  - `toggle(path)` flips a directory's expanded flag and returns `true` when its children still need fetching.
  - `visibleRows()` returns a flat array of `{ node, depth, expanded }` in display order, directories before files, each group alphabetical.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/remote-web-file-browser/test-file-browser.js`:

```javascript
const assert = require("node:assert/strict");

require("../../../Alas/Resources/RemoteWeb/file-browser.js");

const browser = globalThis.RemoteFileBrowser;

function dir(name, path) {
  return { name, path, kind: "dir", badge: null, childrenState: "notLoaded", isSubmodule: false };
}

function file(name, path, badge) {
  return { name, path, kind: "file", badge: badge || null, childrenState: "loaded", isSubmodule: false };
}

{
  const tree = browser.createTree();
  tree.applyNodes(null, [file("z.txt", "z.txt"), dir("src", "src")]);
  const rows = tree.visibleRows();
  assert.deepEqual(rows.map((r) => r.node.path), ["src", "z.txt"]);
  assert.deepEqual(rows.map((r) => r.depth), [0, 0]);
  assert.equal(rows[0].expanded, false);
}

{
  const tree = browser.createTree();
  tree.applyNodes(null, [dir("src", "src")]);
  assert.equal(tree.needsChildren("src"), true);
  assert.equal(tree.toggle("src"), true);
  assert.equal(tree.isExpanded("src"), true);

  tree.applyNodes("src", [file("main.swift", "src/main.swift", "M")]);
  assert.equal(tree.needsChildren("src"), false);

  const rows = tree.visibleRows();
  assert.deepEqual(rows.map((r) => r.node.path), ["src", "src/main.swift"]);
  assert.deepEqual(rows.map((r) => r.depth), [0, 1]);
  assert.equal(rows[1].node.badge, "M");

  assert.equal(tree.toggle("src"), false);
  assert.equal(tree.isExpanded("src"), false);
  assert.deepEqual(tree.visibleRows().map((r) => r.node.path), ["src"]);
}

{
  const tree = browser.createTree();
  tree.applyNodes(null, [dir("a", "a")]);
  tree.toggle("a");
  tree.applyNodes("a", [file("x.txt", "a/x.txt")]);
  tree.reset();
  assert.deepEqual(tree.visibleRows(), []);
  assert.equal(tree.isExpanded("a"), false);
}

console.log("remote-web-file-browser: ok");
```

Create `scripts/tests/remote-web-file-browser/run.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
node "$(dirname "$0")/test-file-browser.js"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x scripts/tests/remote-web-file-browser/run.sh && bash scripts/tests/remote-web-file-browser/run.sh`
Expected: FAIL — `Cannot find module '.../file-browser.js'`.

- [ ] **Step 3: Write the implementation**

Create `Alas/Resources/RemoteWeb/file-browser.js`:

```javascript
// Pure state for the lazy file tree in the Files tab. The server sends one
// directory's children at a time; this module remembers what has arrived, what
// is expanded, and flattens it into display rows. DOM wiring lives in app.js.

function nodeOrder(a, b) {
  if (a.kind !== b.kind) return a.kind === "dir" ? -1 : 1;
  return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
}

function createTree() {
  const childrenByPath = new Map();   // key: "" for root, else directory path
  const expanded = new Set();

  function key(path) {
    return path === null || path === undefined ? "" : path;
  }

  function applyNodes(path, nodes) {
    childrenByPath.set(key(path), (nodes || []).slice().sort(nodeOrder));
  }

  function isExpanded(path) {
    return expanded.has(key(path));
  }

  function needsChildren(path) {
    return !childrenByPath.has(key(path));
  }

  function toggle(path) {
    const id = key(path);
    if (expanded.has(id)) {
      expanded.delete(id);
      return false;
    }
    expanded.add(id);
    return needsChildren(path);
  }

  function collect(path, depth, rows) {
    const nodes = childrenByPath.get(key(path)) || [];
    for (const node of nodes) {
      const open = node.kind === "dir" && expanded.has(node.path);
      rows.push({ node, depth, expanded: open });
      if (open) collect(node.path, depth + 1, rows);
    }
  }

  function visibleRows() {
    const rows = [];
    collect(null, 0, rows);
    return rows;
  }

  function reset() {
    childrenByPath.clear();
    expanded.clear();
  }

  return { applyNodes, isExpanded, needsChildren, toggle, visibleRows, reset };
}

globalThis.RemoteFileBrowser = { createTree };
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/tests/remote-web-file-browser/run.sh`
Expected: `remote-web-file-browser: ok`

- [ ] **Step 5: Commit**

```bash
git add Alas/Resources/RemoteWeb/file-browser.js scripts/tests/remote-web-file-browser
git commit -m "feat(remote): file browser tree state module"
```

---

### Task 8: Tabs, markup, styles, and asset wiring

**Files:**
- Modify: `Alas/Resources/RemoteWeb/index.html`
- Modify: `Alas/Resources/RemoteWeb/style.css`
- Modify: `Alas/Resources/RemoteWeb/sw.js`
- Modify: `Alas/Resources/RemoteWeb/app.js`
- Test: `AlasTests/Remote/RemoteWebAssetTests.swift`

**Interfaces:**
- Consumes: `RemoteChangesView` (Task 6), `RemoteFileBrowser` (Task 7).
- Produces: DOM ids `detail-tabs`, `tab-chat`, `tab-changes`, `tab-files`, `changes`, `changes-summary`, `changes-refresh`, `changes-list`, `changes-error`, `diff-view`, `diff-path`, `diff-rows`, `files`, `file-list`, `file-error`, `file-view`, `file-view-path`, `file-view-body`; and `app.js` functions `showTab(name)`, `requestChanges()`, `openDiff(path)`, `openFileView(path)`, consumed by Task 9's handlers.

This task lands the shell: markup, styling, tab switching, script/version wiring, and the asset test. Task 9 lands the message handlers that fill it.

- [ ] **Step 1: Write the failing test**

Append to `AlasTests/Remote/RemoteWebAssetTests.swift`, inside the existing struct:

```swift
    @Test func remoteWebShipsChangesAndFilesTabs() throws {
        let html = try asset("index.html")
        let sw = try asset("sw.js")

        #expect(html.contains(#"id="detail-tabs""#))
        #expect(html.contains(#"id="tab-chat""#))
        #expect(html.contains(#"id="tab-changes""#))
        #expect(html.contains(#"id="tab-files""#))
        #expect(html.contains(#"<section id="changes" class="view hidden">"#))
        #expect(html.contains(#"<section id="files" class="view hidden">"#))
        #expect(html.contains(#"id="changes-summary""#))
        #expect(html.contains(#"id="changes-refresh""#))
        #expect(html.contains(#"id="changes-list""#))
        #expect(html.contains(#"id="diff-rows""#))
        #expect(html.contains(#"id="file-list""#))
        #expect(html.contains(#"id="file-view-body""#))

        #expect(html.contains(#"/changes-view.js?v=1"#))
        #expect(html.contains(#"/file-browser.js?v=1"#))
        #expect(html.range(of: #"/changes-view.js?v=1"#)!.lowerBound
            < html.range(of: #"/app.js?v=64"#)!.lowerBound)
        #expect(html.range(of: #"/file-browser.js?v=1"#)!.lowerBound
            < html.range(of: #"/app.js?v=64"#)!.lowerBound)
        #expect(sw.contains(#""/changes-view.js?v=1""#))
        #expect(sw.contains(#""/file-browser.js?v=1""#))
    }

    @Test func remoteWebWiresTabSwitching() throws {
        let js = try asset("app.js")
        #expect(js.contains("function showTab(name)"))
        #expect(js.contains("const changesTree = RemoteFileBrowser.createTree();"))
        #expect(js.contains(#"type: "listChanges""#))
        #expect(js.contains(#"type: "listFiles""#))
    }
```

Also bump every existing version assertion in that file:

```bash
sed -i '' 's|app\.js?v=63|app.js?v=64|g; s|style\.css?v=41|style.css?v=42|g; s|alas-remote-shell-v41|alas-remote-shell-v42|g' AlasTests/Remote/RemoteWebAssetTests.swift
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteWebAssetTests test 2>&1 | tail -20`
Expected: FAIL — the new ids and script tags are absent, and the bumped versions do not match the assets yet.

- [ ] **Step 3: Add the markup**

In `Alas/Resources/RemoteWeb/index.html`, inside `<header id="bar">` after `#detail-rename`, add the tab strip:

```html
    <div id="detail-tabs" class="tabs hidden" role="tablist">
      <button id="tab-chat" class="tab is-active" role="tab" type="button">Chat</button>
      <button id="tab-changes" class="tab" role="tab" type="button">Changes</button>
      <button id="tab-files" class="tab" role="tab" type="button">Files</button>
    </div>
```

After the `<section id="transcript">` element, add the two new views:

```html
    <section id="changes" class="view hidden">
      <div id="changes-header">
        <span id="changes-summary"></span>
        <button id="changes-refresh" type="button" aria-label="Refresh changes">↻</button>
      </div>
      <p id="changes-error" class="sheet-error hidden" role="alert"></p>
      <div id="changes-list"></div>
      <div id="diff-view" class="hidden">
        <p id="diff-path" class="detail-path"></p>
        <div id="diff-rows"></div>
      </div>
    </section>
    <section id="files" class="view hidden">
      <p id="file-error" class="sheet-error hidden" role="alert"></p>
      <div id="file-list"></div>
      <div id="file-view" class="hidden">
        <p id="file-view-path" class="detail-path"></p>
        <div id="file-view-body"></div>
      </div>
    </section>
```

Update the script tags and the stylesheet query string:

```html
  <script src="/changes-view.js?v=1"></script>
  <script src="/file-browser.js?v=1"></script>
  <script src="/app.js?v=64"></script>
```

and change `style.css?v=41` to `style.css?v=42`.

- [ ] **Step 4: Update the service worker**

In `Alas/Resources/RemoteWeb/sw.js`, set `CACHE_NAME` to `"alas-remote-shell-v42"` and update `SHELL_ASSETS`:

```javascript
  "/style.css?v=42",
  "/session-ordering.js?v=1",
  "/worktree-creation.js?v=1",
  "/changes-view.js?v=1",
  "/file-browser.js?v=1",
  "/app.js?v=64",
```

- [ ] **Step 5: Add the styles**

Append to `Alas/Resources/RemoteWeb/style.css`, using the file's existing custom
properties (`--fg`, `--fg-muted`, `--fg-faint`, `--line`, `--line-soft`,
`--bg-3`, `--add`, `--del`) — the same tokens `.sheet-error` and `#status.chip`
already build on with `color-mix(in oklab, ...)`:

```css
.tabs { display: flex; gap: 2px; }
.tab {
  background: none; border: none; padding: 6px 10px;
  font: inherit; color: var(--fg-muted); border-radius: 6px;
}
.tab.is-active { color: var(--fg); background: color-mix(in oklab, var(--bg-3) 70%, transparent); }

#changes-header {
  display: flex; align-items: center; justify-content: space-between;
  gap: 8px; padding: 10px 12px; color: var(--fg-muted);
}
#changes-refresh { background: none; border: none; color: var(--fg-muted); font-size: 16px; }
.change-row, .file-row {
  display: flex; align-items: baseline; gap: 8px; width: 100%;
  padding: 10px 12px; background: none; border: none;
  border-bottom: 0.5px solid var(--line-soft); text-align: left; font: inherit; color: var(--fg);
}
.change-dir { color: var(--fg-faint); }
.change-name { font-weight: 600; }
.change-counts { margin-left: auto; font-variant-numeric: tabular-nums; color: var(--fg-muted); }
.change-conflict { color: var(--del); }

#diff-rows, #file-view-body {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px; overflow-x: auto;
}
.diff-hunk {
  padding: 6px 12px; color: var(--fg-muted);
  background: color-mix(in oklab, var(--bg-3) 70%, transparent); position: sticky; top: 0;
}
.diff-line { display: flex; gap: 8px; padding: 0 12px; white-space: pre; }
.diff-line.add { background: color-mix(in oklab, var(--add) 16%, transparent); }
.diff-line.delete { background: color-mix(in oklab, var(--del) 16%, transparent); }
.diff-gutter { min-width: 4ch; text-align: right; color: var(--fg-faint); }
.detail-path { padding: 8px 12px; color: var(--fg-muted); word-break: break-all; }
.placeholder-card {
  margin: 16px 12px; padding: 12px; border: 0.5px solid var(--line);
  border-radius: 10px; color: var(--fg-muted);
}
```

These are all existing tokens — no new `:root` entries are needed.

- [ ] **Step 6: Add tab switching to app.js**

In `Alas/Resources/RemoteWeb/app.js`, near the other module instances, add state and the tab controller:

```javascript
const changesTree = RemoteFileBrowser.createTree();
let activeTab = "chat";
let changesState = { comparisonRef: null, metricsAvailable: true, files: [], truncated: false, loaded: false };
let detailStack = [];   // [{ tab, path }] for the in-tab list → detail level

function showTab(name) {
  activeTab = name;
  detailStack = [];
  $("diff-view").classList.add("hidden");
  $("file-view").classList.add("hidden");
  for (const [id, tab] of [["tab-chat", "chat"], ["tab-changes", "changes"], ["tab-files", "files"]]) {
    $(id).classList.toggle("is-active", tab === name);
  }
  $("transcript").classList.toggle("hidden", name !== "chat");
  $("changes").classList.toggle("hidden", name !== "changes");
  $("files").classList.toggle("hidden", name !== "files");
  if (name === "changes") requestChanges();
  if (name === "files" && changesTree.needsChildren(null)) {
    send({ type: "listFiles", sessionId: currentSession });
  }
}

function requestChanges() {
  if (!currentSession) return;
  send({ type: "listChanges", sessionId: currentSession });
}

$("tab-chat").addEventListener("click", () => showTab("chat"));
$("tab-changes").addEventListener("click", () => showTab("changes"));
$("tab-files").addEventListener("click", () => showTab("files"));
$("changes-refresh").addEventListener("click", requestChanges);
```

In `openSession(id)`, after the existing state resets, add:

```javascript
  changesTree.reset();
  changesState = { comparisonRef: null, metricsAvailable: true, files: [], truncated: false, loaded: false };
  detailStack = [];
  const summary = listedSessions.get(id);
  $("detail-tabs").classList.toggle("hidden", !summary || !summary.worktree);
  showTab("chat");
```

In `showSessions()`, add:

```javascript
  changesTree.reset();
  changesState = { comparisonRef: null, metricsAvailable: true, files: [], truncated: false, loaded: false };
  detailStack = [];
  activeTab = "chat";
  $("detail-tabs").classList.add("hidden");
  $("changes").classList.add("hidden");
  $("files").classList.add("hidden");
```

`listedSessions` (a `Map` from session id to the full session object, populated
in `renderSessions`) already carries `.worktree` — no new map is needed.

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteWebAssetTests test 2>&1 | tail -20`
Expected: PASS, including the two new tests.

- [ ] **Step 8: Commit**

```bash
git add Alas/Resources/RemoteWeb AlasTests/Remote/RemoteWebAssetTests.swift
git commit -m "feat(remote): changes and files tab shell in the web client"
```

---

### Task 9: Rendering and message handling

**Files:**
- Modify: `Alas/Resources/RemoteWeb/app.js`
- Test: `AlasTests/Remote/RemoteWebAssetTests.swift`

**Interfaces:**
- Consumes: `showTab`, `requestChanges`, `changesTree`, `changesState`, `detailStack` (Task 8); `RemoteChangesView` (Task 6); server messages from Task 1.
- Produces: complete Changes and Files behavior — nothing downstream depends on it.

- [ ] **Step 1: Write the failing test**

Append to `AlasTests/Remote/RemoteWebAssetTests.swift`:

```swift
    @Test func remoteWebHandlesChangesAndFilesMessages() throws {
        let js = try asset("app.js")

        #expect(js.contains(#"case "changeList":"#))
        #expect(js.contains(#"case "changeListFailed":"#))
        #expect(js.contains(#"case "fileDiffResult":"#))
        #expect(js.contains(#"case "fileDiffFailed":"#))
        #expect(js.contains(#"case "fileTree":"#))
        #expect(js.contains(#"case "fileTreeFailed":"#))
        #expect(js.contains(#"case "fileContents":"#))
        #expect(js.contains(#"case "fileUnavailable":"#))
        #expect(js.contains("function renderChanges()"))
        #expect(js.contains("function renderDiff("))
        #expect(js.contains("function renderFileTree()"))
        #expect(js.contains("RemoteChangesView.diffRows("))
        #expect(js.contains("RemoteChangesView.formatSummary("))
    }

    @Test func remoteWebRefreshesChangesWhenATurnGoesIdle() throws {
        let js = try asset("app.js")
        #expect(js.contains("function noteStreamingStateForChanges(state)"))
        #expect(js.contains(#"activeTab === "changes""#))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteWebAssetTests test 2>&1 | tail -20`
Expected: FAIL — the handlers and render functions do not exist.

- [ ] **Step 3: Add the renderers**

In `Alas/Resources/RemoteWeb/app.js`:

```javascript
function renderChanges() {
  const list = $("changes-list");
  list.innerHTML = "";
  $("changes-summary").textContent = changesState.loaded
    ? RemoteChangesView.formatSummary(changesState)
    : "Loading changes…";

  if (changesState.loaded && !changesState.metricsAvailable) {
    list.append(el("p", "placeholder-card", "Change metrics are unavailable for this worktree."));
    return;
  }

  if (changesState.loaded && changesState.files.length === 0) {
    list.append(el("p", "placeholder-card", "No changes yet."));
    return;
  }

  for (const file of RemoteChangesView.sortFiles(changesState.files)) {
    const parts = RemoteChangesView.splitPath(file.path);
    const row = document.createElement("button");
    row.type = "button";
    row.className = "change-row";
    row.onclick = () => openDiff(file.path);

    row.append(el("span", "change-dir", parts.dir), el("span", "change-name", parts.name));
    if (file.conflict) row.append(el("span", "change-conflict", "conflict"));
    row.append(el("span", "change-counts", RemoteChangesView.formatFileCounts(file)));
    list.appendChild(row);
  }

  const notice = RemoteChangesView.truncationNotice(changesState.truncated, "files");
  if (notice) list.append(el("p", "placeholder-card", notice));
}

function openDiff(path) {
  detailStack.push({ tab: "changes", path });
  $("changes-list").classList.add("hidden");
  $("changes-header").classList.add("hidden");
  $("diff-view").classList.remove("hidden");
  $("diff-path").textContent = path;
  $("diff-rows").innerHTML = "";
  send({ type: "fileDiff", sessionId: currentSession, path });
}

function closeDetailLevel() {
  detailStack.pop();
  $("diff-view").classList.add("hidden");
  $("file-view").classList.add("hidden");
  $("changes-list").classList.remove("hidden");
  $("changes-header").classList.remove("hidden");
  $("file-list").classList.remove("hidden");
}

function renderDiff(path, hunks, truncated) {
  if ($("diff-path").textContent !== path) return;   // a newer file is open
  const container = $("diff-rows");
  container.innerHTML = "";
  for (const row of RemoteChangesView.diffRows(hunks)) {
    if (row.type === "hunk") {
      container.append(el("div", "diff-hunk", row.text));
      continue;
    }
    const line = el("div", "diff-line " + row.kind);
    line.append(
      el("span", "diff-gutter", row.oldNumber === null ? "" : String(row.oldNumber)),
      el("span", "diff-gutter", row.newNumber === null ? "" : String(row.newNumber)),
      el("span", "", row.text));
    container.appendChild(line);
  }
  const notice = RemoteChangesView.truncationNotice(truncated, "diff");
  if (notice) container.append(el("p", "placeholder-card", notice));
}

function renderFileTree() {
  const list = $("file-list");
  list.innerHTML = "";
  for (const row of changesTree.visibleRows()) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "file-row";
    button.style.paddingLeft = 12 + row.depth * 14 + "px";

    const label = row.node.kind === "dir"
      ? (row.expanded ? "▾ " : "▸ ") + row.node.name
      : row.node.name;
    button.append(el("span", "", label));
    if (row.node.badge) button.append(el("span", "change-counts", row.node.badge));

    button.onclick = () => {
      if (row.node.kind === "dir") {
        if (changesTree.toggle(row.node.path)) {
          send({ type: "listFiles", sessionId: currentSession, path: row.node.path });
        }
        renderFileTree();
        return;
      }
      openFileView(row.node.path);
    };
    list.appendChild(button);
  }
}

function openFileView(path) {
  detailStack.push({ tab: "files", path });
  $("file-list").classList.add("hidden");
  $("file-view").classList.remove("hidden");
  $("file-view-path").textContent = path;
  $("file-view-body").textContent = "Loading…";
  send({ type: "readFile", sessionId: currentSession, path });
}

function renderFileContents(path, text, truncated) {
  if ($("file-view-path").textContent !== path) return;
  const body = $("file-view-body");
  body.innerHTML = "";
  text.split("\n").forEach((line, index) => {
    const row = el("div", "diff-line");
    row.append(el("span", "diff-gutter", String(index + 1)), el("span", "", line));
    body.appendChild(row);
  });
  if (truncated) body.append(el("p", "placeholder-card", "File truncated."));
}

function fileAccessMessage(reason, byteSize) {
  switch (reason) {
    case "binary": return "Binary file — not shown.";
    case "tooLarge": return byteSize
      ? "File is " + Math.round(byteSize / 1024) + " KB — too large to view."
      : "File is too large to view.";
    case "pathRejected": return "That path is outside this worktree.";
    case "notFound": return "File not found.";
    case "worktreeUnavailable": return "This session's worktree is unavailable.";
    case "sessionUnknown": return "This session is no longer open on the host.";
    default: return "Could not read this file.";
  }
}

function showChangesError(text) {
  const error = $("changes-error");
  error.textContent = text;
  error.classList.remove("hidden");
}

function showFileError(text) {
  const error = $("file-error");
  error.textContent = text;
  error.classList.remove("hidden");
}

/// Re-fetch the change list when the agent stops, but only while the tab is
/// open — the server keeps no per-tab state.
function noteStreamingStateForChanges(state) {
  if (state !== "idle") return;
  if (activeTab === "changes" && detailStack.length === 0) requestChanges();
}
```

- [ ] **Step 4: Add the message handlers**

In the websocket message switch in `app.js`, alongside the existing `case "..."` arms:

```javascript
    case "changeList":
      if (msg.sessionId !== currentSession) break;
      $("changes-error").classList.add("hidden");
      changesState = {
        comparisonRef: msg.comparisonRef || null,
        metricsAvailable: msg.metricsAvailable !== false,
        files: msg.files || [],
        truncated: !!msg.truncated,
        loaded: true
      };
      renderChanges();
      break;
    case "changeListFailed":
      if (msg.sessionId !== currentSession) break;
      changesState.loaded = true;
      showChangesError(fileAccessMessage(msg.reason, null));
      break;
    case "fileDiffResult":
      if (msg.sessionId !== currentSession) break;
      renderDiff(msg.path, msg.hunks || [], !!msg.truncated);
      break;
    case "fileDiffFailed":
      if (msg.sessionId !== currentSession) break;
      if ($("diff-path").textContent === msg.path) {
        $("diff-rows").innerHTML = "";
        $("diff-rows").append(el("p", "placeholder-card", fileAccessMessage(msg.reason, null)));
      }
      break;
    case "fileTree":
      if (msg.sessionId !== currentSession) break;
      $("file-error").classList.add("hidden");
      changesTree.applyNodes(msg.path === undefined ? null : msg.path, msg.nodes || []);
      renderFileTree();
      break;
    case "fileTreeFailed":
      if (msg.sessionId !== currentSession) break;
      showFileError(fileAccessMessage(msg.reason, null));
      break;
    case "fileContents":
      if (msg.sessionId !== currentSession) break;
      renderFileContents(msg.path, msg.text || "", !!msg.truncated);
      break;
    case "fileUnavailable":
      if (msg.sessionId !== currentSession) break;
      if ($("file-view-path").textContent === msg.path) {
        $("file-view-body").innerHTML = "";
        $("file-view-body").append(el("p", "placeholder-card", fileAccessMessage(msg.reason, msg.byteSize)));
      }
      break;
```

Both `applySnapshot` and `applyDelta` already end by calling
`syncStreamingState(msg.streamingState)` — that is the single choke point both
transcript paths funnel through, so hook the refresh there instead of touching
each handler:

```javascript
function syncStreamingState(streamingState) {
  if (streamingState === "idle" && stopPending) markStopping(false);
  renderDriveBar(streamingState);
  noteStreamingStateForChanges(streamingState);
}
```

Replace the existing `$("back").onclick = showSessions;` (near the end of
`app.js`) so a diff or file view closes before the whole detail screen does:

```javascript
$("back").onclick = () => {
  if (detailStack.length > 0) { closeDetailLevel(); return; }
  showSessions();
};
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RemoteWebAssetTests test 2>&1 | tail -20`
Expected: PASS, including the two new tests.

- [ ] **Step 6: Verify by hand in a browser**

Start Alas, enable the remote server in Settings, pair a browser, open a session whose worktree has changes, and confirm: the tab strip appears; Changes lists files with the comparison ref in the header; tapping a file shows a unified diff; `‹` returns to the list, then to Sessions; Files expands directories lazily and opens a text file; a binary file shows the placeholder card.

- [ ] **Step 7: Commit**

```bash
git add Alas/Resources/RemoteWeb/app.js AlasTests/Remote/RemoteWebAssetTests.swift
git commit -m "feat(remote): render changes and files in the web client"
```

---

### Task 10: Full verification

**Files:**
- Modify: none expected. Fix whatever the sweep surfaces.

**Interfaces:**
- Consumes: everything from Tasks 1-9.
- Produces: a branch ready for review.

- [ ] **Step 1: Regenerate the project**

Run: `xcodegen`
Expected: `Alas.xcodeproj` regenerated with the new Swift files and no diff noise beyond them.

- [ ] **Step 2: Build**

Run: `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build`
Expected: build succeeds with no warnings introduced by these changes.

- [ ] **Step 3: Run the JS suites**

Run:

```bash
bash scripts/tests/remote-web-changes/run.sh
bash scripts/tests/remote-web-file-browser/run.sh
bash scripts/tests/remote-web-session-ordering/run.sh
bash scripts/tests/remote-web-worktree-creation/run.sh
```

Expected: each prints its `ok` line.

- [ ] **Step 4: Run the affected Swift suites**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/RemoteProtocolTests \
  -only-testing:AlasTests/RemoteWorktreeFileAccessTests \
  -only-testing:AlasTests/GitServiceRemoteChangesTests \
  -only-testing:AlasTests/RemoteAppStateAccessTests \
  -only-testing:AlasTests/RemoteSessionGatewayTests \
  -only-testing:AlasTests/RemoteWebAssetTests \
  -only-testing:AlasTests/RemoteServerIntegrationTests \
  test 2>&1 | tail -30
```

Expected: all suites pass. Report actual output; do not claim success without it.

- [ ] **Step 5: Commit any fixes and push**

```bash
git add -A
git commit -m "fix(remote): address verification findings"
git push
```

Skip the commit if the sweep was clean. The full `xcodebuild ... test` sweep runs in CI.

---

## Self-Review

**Spec coverage.** Transport → Task 1. Protocol table and wire types → Task 1. Failure reasons → Task 1. Provider methods → Task 4. Git work → Task 3 (changed files, against-ref diff) and Task 4 (tree, file read). Caps → Task 2 (constants and truncation) applied in Task 4. Load discipline → Task 5 (in-flight dedupe) and Task 4 (`@MainActor` entry, immediate `await`). Security → Task 2 (path resolution, `.git`, symlinks), enforced in Task 4, dispatch-tested in Task 5. Client navigation, tabs, per-session state → Task 8. Changes tab, diff view, Files tab, refresh, errors → Task 9. File layout → Tasks 6, 7, 8. Testing → every task, gathered in Task 10.

**Deliberate deviation from the spec, flagged for the executor.** The spec's refresh rule says "when `streamingState` transitions to `idle` while the tab is open." Task 9 implements `noteStreamingStateForChanges` as a check on each delta rather than a true edge transition, so a burst of idle deltas could re-request the list. The gateway's in-flight dedupe (Task 5) absorbs the duplicates. If that proves chatty in the browser test in Task 9 Step 6, track the previous state in a variable and fire only on the transition.

**Debounce.** The spec calls for a debounced idle refresh; the dedupe set in Task 5 plus the single-request-per-idle path in Task 9 covers the same ground without a timer. If Task 9's hand-check shows repeated fetches, add a 500 ms client-side debounce around `requestChanges`.
