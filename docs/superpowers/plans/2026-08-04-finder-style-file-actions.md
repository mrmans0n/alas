# Finder-Style File Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Finder-style Open, Open With, and general file context actions to Working Tree and Files-tab rows.

**Architecture:** Extend `FileSystemOpen` with a testable Launch Services application model. Add a shared `FileContextMenuActions` SwiftUI view driven by a pure action-order configuration and a target that removes local-system actions for remote or missing paths. Working Tree and Files provide different configurations while sharing rendering and system behavior.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit `NSWorkspace`, macOS 15.0, Swift Testing, XcodeGen/Xcode.

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Use Swift Testing (`import Testing`), not XCTest.
- Keep the deployment target at macOS 15.0 and add no dependencies.
- Keep Git mutations in Changes; do not add Stage, Unstage, Discard, Ignore, or Copy Diff to Files.
- Omit Open, Open With, and Reveal in Finder for remote or missing targets.
- Do not add agent attribution to code, documentation, commits, or PR text.
- Run `xcodegen` when adding Swift files and commit generated `Alas.xcodeproj` changes with them.

---

## File Structure

- Modify `Alas/Sources/Center/FileSystemOpen.swift`: Launch Services discovery, ordering, icons, and selected-app opening.
- Create `Alas/Sources/Right/FileContextMenuActions.swift`: target resolution, action configurations, and shared menu rendering.
- Modify `Alas/Sources/Right/ChangedRow.swift`, `WorkingTreeSectionView.swift`, and `ChangesTabView.swift`: Working Tree integration.
- Modify `Alas/Sources/Right/FilesTabView.swift` and `RightPaneView.swift`: Files-tab integration.
- Create `AlasTests/FileSystemOpenTests.swift` and `AlasTests/FileContextMenuActionsTests.swift`.
- Regenerate `Alas.xcodeproj/project.pbxproj`.

---

### Task 1: Launch Services Application Discovery

**Files:**
- Modify: `Alas/Sources/Center/FileSystemOpen.swift:1-17`
- Create: `AlasTests/FileSystemOpenTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via `xcodegen`

**Interfaces:**
- Consumes: `NSWorkspace.urlsForApplications(toOpen:)`, `urlForApplication(toOpen:)`, and the existing default-open/reveal methods.
- Produces: `FileSystemApplication`, `applications(for:)`, `orderedApplications(candidateURLs:defaultApplicationURL:displayName:)`, and `open(url:with:)`.

- [ ] **Step 1: Write the failing tests**

Create `AlasTests/FileSystemOpenTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

struct FileSystemOpenTests {
    @Test func ordersDefaultFirstDeduplicatesAndSortsByName() {
        let preview = URL(fileURLWithPath: "/Applications/Preview.app")
        let duplicatePreview = URL(fileURLWithPath: "/Applications/Utilities/../Preview.app")
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
        let names = [
            preview.standardizedFileURL.path: "Preview",
            textEdit.standardizedFileURL.path: "TextEdit",
            xcode.standardizedFileURL.path: "Xcode"
        ]

        let applications = FileSystemOpen.orderedApplications(
            candidateURLs: [xcode, duplicatePreview, textEdit, preview],
            defaultApplicationURL: textEdit,
            displayName: { names[$0.standardizedFileURL.path] ?? $0.lastPathComponent }
        )

        #expect(applications.map(\.url) == [textEdit, preview, xcode])
        #expect(applications.map(\.name) == ["TextEdit", "Preview", "Xcode"])
        #expect(applications.map(\.isDefault) == [true, false, false])
        #expect(applications.map(\.menuTitle) == ["TextEdit (default)", "Preview", "Xcode"])
    }

    @Test func includesDefaultWhenCandidateListOmitsIt() {
        let preview = URL(fileURLWithPath: "/Applications/Preview.app")
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

        let applications = FileSystemOpen.orderedApplications(
            candidateURLs: [preview],
            defaultApplicationURL: textEdit,
            displayName: { $0.deletingPathExtension().lastPathComponent }
        )

        #expect(applications.map(\.url) == [textEdit, preview])
        #expect(applications.first?.isDefault == true)
    }
}
```

- [ ] **Step 2: Regenerate and confirm the test fails**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/FileSystemOpenTests
```

Expected: compilation fails because the application model and ordering method do not exist.

- [ ] **Step 3: Implement the model and bridge**

Replace `FileSystemOpen.swift` with:

```swift
import AppKit

struct FileSystemApplication: Identifiable, Equatable {
    let url: URL
    let name: String
    let isDefault: Bool

    var id: String { url.standardizedFileURL.path }
    var menuTitle: String { isDefault ? "\(name) (default)" : name }

    @MainActor var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum FileSystemOpen {
    @MainActor static func open(url: URL) {
        NSWorkspace.shared.open(url)
    }

    @MainActor static func open(url: URL, with application: FileSystemApplication) {
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: application.url,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    @MainActor static func reveal(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor static func applications(for url: URL) -> [FileSystemApplication] {
        let workspace = NSWorkspace.shared
        return orderedApplications(
            candidateURLs: workspace.urlsForApplications(toOpen: url),
            defaultApplicationURL: workspace.urlForApplication(toOpen: url),
            displayName: applicationDisplayName(for:)
        )
    }

    static func orderedApplications(
        candidateURLs: [URL],
        defaultApplicationURL: URL?,
        displayName: (URL) -> String
    ) -> [FileSystemApplication] {
        let defaultURL = defaultApplicationURL?.standardizedFileURL
        var uniqueURLs: [String: URL] = [:]
        for url in candidateURLs + [defaultApplicationURL].compactMap({ $0 }) {
            let standardized = url.standardizedFileURL
            if uniqueURLs[standardized.path] == nil {
                uniqueURLs[standardized.path] = standardized
            }
        }
        return uniqueURLs.values
            .map { url in
                FileSystemApplication(
                    url: url,
                    name: displayName(url),
                    isDefault: url == defaultURL
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
                let order = lhs.name.localizedStandardCompare(rhs.name)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
            }
    }

    private static func applicationDisplayName(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.localizedNameKey])
        let rawName = values?.localizedName ?? url.lastPathComponent
        return rawName.hasSuffix(".app") ? String(rawName.dropLast(4)) : rawName
    }
}
```

- [ ] **Step 4: Run the focused test**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/FileSystemOpenTests
```

Expected: `FileSystemOpenTests` passes.

- [ ] **Step 5: Commit**

```bash
git add Alas/Sources/Center/FileSystemOpen.swift AlasTests/FileSystemOpenTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat: add system application discovery"
```

---

### Task 2: Shared Menu and Working Tree Integration

**Files:**
- Create: `Alas/Sources/Right/FileContextMenuActions.swift`
- Modify: `Alas/Sources/Right/ChangedRow.swift:3-89`
- Modify: `Alas/Sources/Right/WorkingTreeSectionView.swift:3-25, 142-257`
- Modify: `Alas/Sources/Right/ChangesTabView.swift:1-2, 230-286`
- Create: `AlasTests/FileContextMenuActionsTests.swift`
- Modify: `Alas.xcodeproj/project.pbxproj` via `xcodegen`

**Interfaces:**
- Consumes: Task 1's `FileSystemApplication` and `FileSystemOpen` API, `FileTreeNode.Kind`, and existing Working Tree callbacks.
- Produces: `FileContextMenuTarget.resolve`, `FileContextMenuAction`, `FileContextMenuConfiguration.workingTreeFile`, and `FileContextMenuActions`.

- [ ] **Step 1: Write failing target and action-order tests**

Create `AlasTests/FileContextMenuActionsTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

struct FileContextMenuActionsTests {
    @Test func resolvesExistingLocalFileButRejectsMissingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-context-menu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("README.md")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let existing = FileContextMenuTarget.resolve(kind: .file, worktreePath: root, relativePath: "README.md")
        let missing = FileContextMenuTarget.resolve(kind: .file, worktreePath: root, relativePath: "missing.md")

        #expect(existing.localURL == file)
        #expect(missing.localURL == nil)
    }

    @Test func remoteTargetOmitsLocalURL() {
        let root = URL(fileURLWithPath: "/srv/remote-\(UUID().uuidString)")
        RemoteHostRegistry.shared.register(root: root.path, host: "devbox")
        defer { RemoteHostRegistry.shared.unregister(root: root.path) }
        let target = FileContextMenuTarget.resolve(
            kind: .file,
            worktreePath: root,
            relativePath: "Sources/App.swift",
            fileExists: { _ in true }
        )
        #expect(target.localURL == nil)
    }

    @Test func workingTreeFileOrdersFinderAndRevisionActions() {
        let target = FileContextMenuTarget(kind: .file, localURL: URL(fileURLWithPath: "/repo/App.swift"))
        #expect(FileContextMenuConfiguration.workingTreeFile(target: target).actions == [
            .openInAlas, .open, .openWith, .viewAtHEAD, .compareWithHEAD,
            .fileHistory, .copyRelativePath, .copyFullPath, .revealInFinder
        ])
    }

    @Test func workingTreeMissingTargetKeepsNonSystemActions() {
        let target = FileContextMenuTarget(kind: .file, localURL: nil)
        #expect(FileContextMenuConfiguration.workingTreeFile(target: target).actions == [
            .openInAlas, .viewAtHEAD, .compareWithHEAD,
            .fileHistory, .copyRelativePath, .copyFullPath
        ])
    }
}
```

- [ ] **Step 2: Regenerate and confirm failure**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/FileContextMenuActionsTests
```

Expected: compilation fails because the context-menu types do not exist.

- [ ] **Step 3: Implement target and action configuration**

Create `FileContextMenuActions.swift` with:

```swift
import AppKit
import SwiftUI

struct FileContextMenuTarget: Equatable {
    let kind: FileTreeNode.Kind
    let localURL: URL?

    static func resolve(
        kind: FileTreeNode.Kind,
        worktreePath: URL,
        relativePath: String,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> Self {
        guard !worktreePath.isRemoteAlasPath else { return Self(kind: kind, localURL: nil) }
        let url = worktreePath.appendingPathComponent(relativePath)
        return Self(kind: kind, localURL: fileExists(url) ? url : nil)
    }
}

enum FileContextMenuAction: Hashable {
    case openInAlas, open, openWith, viewAtHEAD, compareWithHEAD
    case fileHistory, copyRelativePath, copyFullPath, revealInFinder
}

struct FileContextMenuConfiguration: Equatable {
    let target: FileContextMenuTarget
    let actions: [FileContextMenuAction]

    static func workingTreeFile(target: FileContextMenuTarget) -> Self {
        var actions: [FileContextMenuAction] = [.openInAlas]
        if target.localURL != nil { actions += [.open, .openWith] }
        actions += [.viewAtHEAD, .compareWithHEAD, .fileHistory, .copyRelativePath, .copyFullPath]
        if target.localURL != nil { actions.append(.revealInFinder) }
        return Self(target: target, actions: actions)
    }
}
```

- [ ] **Step 4: Implement the reusable renderer**

Append:

```swift
struct FileContextMenuActions: View {
    let configuration: FileContextMenuConfiguration
    var onOpenInAlas: (() -> Void)? = nil
    var openInAlasEnabled = true
    var onViewAtHEAD: (() -> Void)? = nil
    var viewAtHEADEnabled = true
    var onCompareWithHEAD: (() -> Void)? = nil
    var onFileHistory: (() -> Void)? = nil
    var onCopyRelativePath: (() -> Void)? = nil
    var onCopyFullPath: (() -> Void)? = nil

    @ViewBuilder var body: some View {
        ForEach(configuration.actions, id: \.self) { action in
            switch action {
            case .openInAlas:
                Button("Open in Alas") { onOpenInAlas?() }
                    .disabled(!openInAlasEnabled || onOpenInAlas == nil)
            case .open:
                if let url = configuration.target.localURL {
                    Button("Open") { FileSystemOpen.open(url: url) }
                }
            case .openWith:
                if let url = configuration.target.localURL { openWithMenu(url: url) }
            case .viewAtHEAD:
                Button("View at HEAD") { onViewAtHEAD?() }
                    .disabled(!viewAtHEADEnabled || onViewAtHEAD == nil)
            case .compareWithHEAD:
                Button("Compare with HEAD") { onCompareWithHEAD?() }
                    .disabled(onCompareWithHEAD == nil)
            case .fileHistory:
                Button("File History") { onFileHistory?() }
                    .disabled(onFileHistory == nil)
            case .copyRelativePath:
                Button("Copy Relative Path") { onCopyRelativePath?() }
                    .disabled(onCopyRelativePath == nil)
            case .copyFullPath:
                Button("Copy Full Path") { onCopyFullPath?() }
                    .disabled(onCopyFullPath == nil)
            case .revealInFinder:
                if let url = configuration.target.localURL {
                    Button("Reveal in Finder") { FileSystemOpen.reveal(url: url) }
                }
            }
        }
    }

    @ViewBuilder private func openWithMenu(url: URL) -> some View {
        Menu("Open With") {
            let applications = FileSystemOpen.applications(for: url)
            if applications.isEmpty {
                Button("No Compatible Applications") {}.disabled(true)
            } else {
                ForEach(applications) { application in
                    Button { FileSystemOpen.open(url: url, with: application) } label: {
                        Label {
                            Text(application.menuTitle)
                        } icon: {
                            Image(nsImage: application.icon).resizable().frame(width: 16, height: 16)
                        }
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 5: Integrate ChangedRow**

Add `let fileContextTarget: FileContextMenuTarget`, remove `onRevealInFinder`, and replace its general menu buttons with:

```swift
FileContextMenuActions(
    configuration: .workingTreeFile(target: fileContextTarget),
    onOpenInAlas: onOpenFile,
    openInAlasEnabled: openFileEnabled,
    onViewAtHEAD: onViewAtHEAD,
    viewAtHEADEnabled: viewAtHEADEnabled,
    onCompareWithHEAD: onCompareWithHEAD,
    onFileHistory: onFileHistory,
    onCopyRelativePath: onCopyRelative,
    onCopyFullPath: onCopyFull
)
```

Keep the existing divider, Copy Diff, staging, discard, and ignore blocks after it.

- [ ] **Step 6: Wire WorkingTreeSectionView and ChangesTabView**

Add this required `WorkingTreeSectionView` input:

```swift
let fileContextTarget: (ChangedFile) -> FileContextMenuTarget
```

Pass `fileContextTarget(file)` to `ChangedRow`, and remove the old `onRevealInFinder` property and argument. In `ChangesTabView`, remove `import AppKit`, remove the old Finder callback, and add:

```swift
fileContextTarget: { file in
    FileContextMenuTarget.resolve(
        kind: .file,
        worktreePath: rps.worktree.path,
        relativePath: file.path
    )
},
```

- [ ] **Step 7: Test and build**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/FileContextMenuActionsTests
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: focused tests pass and Working Tree compiles with the shared menu.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources/Right/FileContextMenuActions.swift Alas/Sources/Right/ChangedRow.swift Alas/Sources/Right/WorkingTreeSectionView.swift Alas/Sources/Right/ChangesTabView.swift AlasTests/FileContextMenuActionsTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat: add system file actions to changes"
```

---

### Task 3: Files-Tab Context Menus

**Files:**
- Modify: `Alas/Sources/Right/FileContextMenuActions.swift`
- Modify: `Alas/Sources/Right/FilesTabView.swift:3-13, 79-204`
- Modify: `Alas/Sources/Right/RightPaneView.swift:75-92`
- Modify: `AlasTests/FileContextMenuActionsTests.swift`

**Interfaces:**
- Consumes: Task 2's shared context-menu types and `AppState.openFileHistory(relativePath:worktreeId:)`.
- Produces: `FileContextMenuConfiguration.filesTab(target:)` and Files-tab file/directory menus.

- [ ] **Step 1: Write failing Files-tab configuration tests**

Append inside `FileContextMenuActionsTests`:

```swift
@Test func filesTabFileHasGeneralFinderActionsOnly() {
    let target = FileContextMenuTarget(kind: .file, localURL: URL(fileURLWithPath: "/repo/README.md"))
    #expect(FileContextMenuConfiguration.filesTab(target: target).actions == [
        .openInAlas, .open, .openWith, .fileHistory,
        .copyRelativePath, .copyFullPath, .revealInFinder
    ])
}

@Test func filesTabDirectoryOmitsEditorHistoryAndOpenWith() {
    let target = FileContextMenuTarget(kind: .dir, localURL: URL(fileURLWithPath: "/repo/Sources"))
    #expect(FileContextMenuConfiguration.filesTab(target: target).actions == [
        .open, .copyRelativePath, .copyFullPath, .revealInFinder
    ])
}

@Test func remoteFilesTabTargetsKeepPortableActions() {
    let file = FileContextMenuTarget(kind: .file, localURL: nil)
    let directory = FileContextMenuTarget(kind: .dir, localURL: nil)
    #expect(FileContextMenuConfiguration.filesTab(target: file).actions == [
        .openInAlas, .fileHistory, .copyRelativePath, .copyFullPath
    ])
    #expect(FileContextMenuConfiguration.filesTab(target: directory).actions == [
        .copyRelativePath, .copyFullPath
    ])
}
```

- [ ] **Step 2: Confirm failure**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/FileContextMenuActionsTests
```

Expected: compilation fails because `filesTab(target:)` does not exist.

- [ ] **Step 3: Add the Files configuration**

Add to `FileContextMenuConfiguration`:

```swift
static func filesTab(target: FileContextMenuTarget) -> Self {
    var actions: [FileContextMenuAction] = []
    if target.kind == .file { actions.append(.openInAlas) }
    if target.localURL != nil {
        actions.append(.open)
        if target.kind == .file { actions.append(.openWith) }
    }
    if target.kind == .file { actions.append(.fileHistory) }
    actions += [.copyRelativePath, .copyFullPath]
    if target.localURL != nil { actions.append(.revealInFinder) }
    return Self(target: target, actions: actions)
}
```

- [ ] **Step 4: Add FilesTabView inputs and menu helper**

Add:

```swift
let worktreePath: URL
let onFileHistory: (FileTreeNode) -> Void
```

Add below `renderNode`:

```swift
@ViewBuilder private func contextMenu(for node: FileTreeNode) -> some View {
    let target = FileContextMenuTarget.resolve(
        kind: node.kind,
        worktreePath: worktreePath,
        relativePath: node.path
    )
    FileContextMenuActions(
        configuration: .filesTab(target: target),
        onOpenInAlas: node.kind == .file ? { onSelectFile(node) } : nil,
        onFileHistory: node.kind == .file ? { onFileHistory(node) } : nil,
        onCopyRelativePath: { Clipboard.copy(node.path) },
        onCopyFullPath: { Clipboard.copy(worktreePath.appendingPathComponent(node.path).path) }
    )
}
```

- [ ] **Step 5: Attach the row menus**

After the directory button's `.buttonStyle(.plain)`, add:

```swift
.contextMenu { contextMenu(for: terminal) }
```

Using `terminal` makes a compacted `Sources/Center` row act on the displayed terminal directory. After the file button's `.buttonStyle(.plain)`, add:

```swift
.contextMenu { contextMenu(for: node) }
```

- [ ] **Step 6: Wire RightPaneView**

Add these arguments to `FilesTabView`:

```swift
worktreePath: worktree.path,
onFileHistory: { node in
    state.openFileHistory(relativePath: node.path, worktreeId: worktree.id)
},
```

- [ ] **Step 7: Test, regenerate, and build**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -only-testing:AlasTests/FileContextMenuActionsTests
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: focused tests pass and both Files-tab row types compile with context menus.

- [ ] **Step 8: Commit**

```bash
git add Alas/Sources/Right/FileContextMenuActions.swift Alas/Sources/Right/FilesTabView.swift Alas/Sources/Right/RightPaneView.swift AlasTests/FileContextMenuActionsTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat: add contextual actions to files tab"
```

---

### Task 4: Full Verification

**Files:**
- Verify: all files modified in Tasks 1-3
- Modify only if regeneration changes it: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: the completed Finder-style menus.
- Produces: a clean build, passing full suite, and clean generated project state.

- [ ] **Step 1: Regenerate and inspect**

```bash
xcodegen
git diff --check
git status --short
```

Expected: XcodeGen succeeds and `git diff --check` reports no errors.

- [ ] **Step 2: Build**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit code 0.

- [ ] **Step 3: Run the full test suite**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: exit code 0 and all tests pass.

- [ ] **Step 4: Commit a generated-project change only if present**

If `git status --short` lists `Alas.xcodeproj/project.pbxproj`, run:

```bash
git add Alas.xcodeproj/project.pbxproj
git commit -m "chore: regenerate Xcode project"
```

If status is clean, do not create an empty commit.

- [ ] **Step 5: Record final evidence**

```bash
git status --short
git log -5 --oneline
```

Expected: the worktree is clean and the design plus three feature commits are visible, along with an optional generated-project commit.
