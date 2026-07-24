# New Run Script Dialog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the native new-run-script alert with an Alas-styled sheet that lets users choose whether the script pane stays open or closes on exit.

**Architecture:** Extract the custom worktree segmented selector into a reusable SwiftUI control, then introduce a small run-script creation model that owns normalization and filesystem writes. `AppState` coordinates presentation, worktree resolution, creation, and editor opening; `NewRunScriptDialog` owns only transient form and inline-error state.

**Tech Stack:** Swift 5.9, SwiftUI for macOS 15, AppKit hosting tests, Swift Testing, XcodeGen, `FileManager`.

## Global Constraints

- Keep code, comments, logs, and UI strings in English.
- Use Swift Testing (`import Testing`), not XCTest.
- Preserve `# alas-on-exit: keep` as the default for both repo and global scripts.
- Use the accurate UI labels **Keep pane open** and **Close pane**.
- Keep filename slugification and existing run/focus/restart/pane-exit semantics unchanged.
- Do not add dependencies or perform unrelated refactors.
- After adding Swift files, run `xcodegen` and include the regenerated `Alas.xcodeproj/project.pbxproj`.
- Prefix shell commands with `rtk`.
- Do not add agent attribution to code, commits, or documentation.

---

### Task 1: Extract the reusable Alas segmented control

**Files:**
- Create: `Alas/Sources/UI/AlasSegmentedControl.swift`
- Modify: `Alas/Sources/Dialogs/NewWorktreeDialog.swift:1-34,482-638`
- Modify: `AlasTests/TouchTargetSmokeTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `Theme`, `Icon`, and SwiftUI `FocusState`.
- Produces:
  - `AlasSegmentedOption<ID: Hashable>`
  - `AlasSegmentedControl<ID: Hashable>`
  - initializer `init(selection: ID, options: [AlasSegmentedOption<ID>], onSelect: @escaping (ID) -> Void)`

- [ ] **Step 1: Add a smoke test that requires the reusable control**

Append this test to `TouchTargetSmokeTests`:

```swift
@Test func alasSegmentedControlRendersEnabledAndDisabledOptions() {
    enum Choice: Hashable { case keep, close }
    let view = AlasSegmentedControl(
        selection: Choice.keep,
        options: [
            AlasSegmentedOption(id: .keep, label: "Keep pane open"),
            AlasSegmentedOption(
                id: .close,
                label: "Close pane",
                isEnabled: false,
                disabledHelp: "Unavailable"
            ),
        ],
        onSelect: { _ in }
    )
    .environment(\.theme, currentTheme())

    let controller = NSHostingController(rootView: view)
    controller.view.layoutSubtreeIfNeeded()

    #expect(controller.view.fittingSize.width > 0)
    #expect(controller.view.fittingSize.height > 0)
}
```

- [ ] **Step 2: Run the focused test and verify the missing type fails**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/TouchTargetSmokeTests/alasSegmentedControlRendersEnabledAndDisabledOptions test
```

Expected: FAIL to compile because `AlasSegmentedControl` and `AlasSegmentedOption` do not exist.

- [ ] **Step 3: Implement the reusable control**

Create `Alas/Sources/UI/AlasSegmentedControl.swift`:

```swift
import SwiftUI

struct AlasSegmentedOption<ID: Hashable> {
    let id: ID
    let label: String
    let icon: String?
    let isEnabled: Bool
    let disabledHelp: String?

    init(
        id: ID,
        label: String,
        icon: String? = nil,
        isEnabled: Bool = true,
        disabledHelp: String? = nil
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.isEnabled = isEnabled
        self.disabledHelp = disabledHelp
    }
}

struct AlasSegmentedControl<ID: Hashable>: View {
    let selection: ID
    let options: [AlasSegmentedOption<ID>]
    let onSelect: (ID) -> Void

    @FocusState private var focusedOption: ID?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.id) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(theme.color("seg-container-bg"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func segment(_ option: AlasSegmentedOption<ID>) -> some View {
        let isSelected = selection == option.id
        let isFocused = focusedOption == option.id
        return Button {
            onSelect(option.id)
        } label: {
            HStack(spacing: 5) {
                if let icon = option.icon {
                    Icon(
                        name: icon,
                        size: 11,
                        color: isSelected ? theme.color("fg") : theme.color("fg-muted")
                    )
                }
                Text(option.label)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? theme.color("fg") : theme.color("fg-muted"))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background {
                if isSelected {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4).fill(theme.color("bg-3"))
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.04), lineWidth: 1)
                            .blendMode(.plusLighter)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(theme.color("accent"), lineWidth: isFocused ? 1 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(option.isEnabled)
        .focused($focusedOption, equals: option.id)
        .disabled(!option.isEnabled)
        .opacity(option.isEnabled ? 1 : 0.4)
        .modifier(AlasSegmentHelpModifier(
            text: option.isEnabled ? nil : option.disabledHelp
        ))
    }
}

private struct AlasSegmentHelpModifier: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
```

- [ ] **Step 4: Migrate both new-worktree selectors without changing behavior**

Remove `focusedGGModeSegment`, `focusedLaunchSurfaceSegment`, the private
`segment` function, `SegmentedContainerStyle`, and `SegmentHelpModifier` from
`NewWorktreeDialog`.

Replace `ggModeSegmented` with:

```swift
private var ggModeSegmented: some View {
    HStack(spacing: 0) {
        AlasSegmentedControl(
            selection: ggMode,
            options: Self.ggModeSegments.map {
                AlasSegmentedOption(id: $0.mode, label: $0.label)
            },
            onSelect: { ggMode = $0 }
        )
        Spacer(minLength: 0)
    }
}
```

Replace `launchSurfaceSegmented` with:

```swift
private var launchSurfaceSegmented: some View {
    HStack(spacing: 0) {
        AlasSegmentedControl(
            selection: selectedLaunchSurfaceSegment,
            options: [
                AlasSegmentedOption(id: .none, label: "No tab", icon: "circle.slash"),
                AlasSegmentedOption(id: .terminal, label: "Terminal", icon: "terminal"),
                AlasSegmentedOption(
                    id: .acp,
                    label: "Chat",
                    icon: "sparkle",
                    isEnabled: acpSegmentEnabled,
                    disabledHelp: "Enable an ACP-capable agent in Settings → Agents."
                ),
            ],
            onSelect: selectLaunchSurface
        )
        Spacer(minLength: 0)
    }
}

private var selectedLaunchSurfaceSegment: NewWorktreeLaunchSurfaceSegment {
    if !openAfterCreate { return .none }
    return launchMode == .terminal ? .terminal : .acp
}

private func selectLaunchSurface(_ segment: NewWorktreeLaunchSurfaceSegment) {
    switch segment {
    case .none:
        openAfterCreate = false
    case .terminal:
        openAfterCreate = true
        launchMode = .terminal
        persistableLaunchMode = .terminal
        launchAgentId = Self.resolvedLaunchAgent(
            initialAgentId: launchAgentId,
            mode: .terminal,
            enabledAgents: state.agentRegistry.enabled()
        )
    case .acp:
        guard acpSegmentEnabled else { return }
        openAfterCreate = true
        launchMode = .acp
        persistableLaunchMode = .acp
        launchAgentId = Self.resolvedLaunchAgent(
            initialAgentId: launchAgentId,
            mode: .acp,
            enabledAgents: state.agentRegistry.enabled()
        )
    }
}
```

- [ ] **Step 5: Regenerate and run focused selector coverage**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/TouchTargetSmokeTests \
  -only-testing:AlasTests/NewWorktreeDialogTests test
```

Expected: PASS. Existing new-worktree ordering, focusability policy, and launch-default tests remain green; the new control renders both enabled and disabled options.

- [ ] **Step 6: Commit the extraction**

```bash
rtk git add Alas/Sources/UI/AlasSegmentedControl.swift \
  Alas/Sources/Dialogs/NewWorktreeDialog.swift \
  AlasTests/TouchTargetSmokeTests.swift \
  Alas.xcodeproj/project.pbxproj
rtk git commit -m "refactor(ui): share dialog segmented control"
```

---

### Task 2: Add testable run-script creation primitives

**Files:**
- Create: `Alas/Sources/RunScripts/RunScriptCreation.swift`
- Modify: `Alas/Sources/RunScripts/RunScript.swift:11-17`
- Modify: `Alas/Sources/RunScripts/RunScriptTemplate.swift`
- Create: `AlasTests/RunScriptCreationTests.swift`
- Modify: `AlasTests/RunScriptTemplateTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `RunScriptScope`, `RunScriptOnExit`, `RunScriptStore.repoScriptsDir`, and `RunScriptTemplate`.
- Produces:
  - `RunScriptCreationPresentation`
  - `RunScriptCreationError`
  - `RunScriptCreator.normalizedName(_:) -> String?`
  - `RunScriptCreator.create(scope:name:onExit:worktreeRoot:globalDir:fileManager:) throws -> URL`
  - `RunScriptTemplate.contents(name:onExit:) -> String`

- [ ] **Step 1: Add failing template tests for both exit behaviors**

Change the existing template tests to call the explicit exit argument and add
the close case:

```swift
@Test func contentsEmbedNameAndKeepDefault() {
    let contents = RunScriptTemplate.contents(name: "Dev Server", onExit: .keep)
    #expect(contents.hasPrefix("#!/bin/zsh\n"))
    #expect(contents.contains("# alas-name: Dev Server"))
    #expect(contents.contains("# alas-on-exit: keep"))
    #expect(contents.hasSuffix("\n"))
}

@Test func contentsEmbedCloseOnExit() {
    let contents = RunScriptTemplate.contents(name: "Dev Server", onExit: .close)
    #expect(contents.contains("# alas-on-exit: close"))
    let meta = RunScriptMetadata.parse(fileName: "dev-server.sh", contents: contents)
    #expect(meta.onExit == .close)
}
```

Keep the round-trip test, but pass `onExit: .keep`.

- [ ] **Step 2: Add failing creation-model tests**

Create `AlasTests/RunScriptCreationTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

struct RunScriptCreationTests {
    @Test func presentationDescribesRepoAndGlobalScopes() {
        let repo = RunScriptCreationPresentation(
            scope: .repo,
            projectId: "project",
            worktreeId: "worktree",
            repositoryName: "Alas"
        )
        let global = RunScriptCreationPresentation(
            scope: .global,
            projectId: "project",
            worktreeId: "worktree",
            repositoryName: "Alas"
        )

        #expect(repo.subtitle == "Create a script in .alas/scripts/ for Alas.")
        #expect(global.subtitle == "Create a script available in every local worktree.")
    }

    @Test func normalizedNameTrimsAndRejectsWhitespace() {
        #expect(RunScriptCreator.normalizedName("  Dev Server \n") == "Dev Server")
        #expect(RunScriptCreator.normalizedName(" \n\t") == nil)
    }

    @Test func createWritesSelectedMetadataAndExecutablePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try RunScriptCreator.create(
            scope: .repo,
            name: " Dev Server ",
            onExit: .close,
            worktreeRoot: root,
            globalDir: root.appendingPathComponent("global")
        )

        #expect(url == root.appendingPathComponent(".alas/scripts/dev-server.sh"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("# alas-name: Dev Server"))
        #expect(contents.contains("# alas-on-exit: close"))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test func createUsesInjectedGlobalDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent("global", isDirectory: true)

        let url = try RunScriptCreator.create(
            scope: .global,
            name: "Build",
            onExit: .keep,
            worktreeRoot: root.appendingPathComponent("worktree"),
            globalDir: global
        )

        #expect(url == global.appendingPathComponent("build.sh"))
    }

    @Test func duplicateReturnsFileExistsWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try RunScriptCreator.create(
            scope: .repo,
            name: "Build",
            onExit: .keep,
            worktreeRoot: root,
            globalDir: root.appendingPathComponent("global")
        )

        #expect(throws: RunScriptCreationError.fileExists("build.sh")) {
            try RunScriptCreator.create(
                scope: .repo,
                name: "Build",
                onExit: .close,
                worktreeRoot: root,
                globalDir: root.appendingPathComponent("global")
            )
        }
        let contents = try String(
            contentsOf: root.appendingPathComponent(".alas/scripts/build.sh"),
            encoding: .utf8
        )
        #expect(contents.contains("# alas-on-exit: keep"))
    }
}
```

- [ ] **Step 3: Regenerate and verify the new tests fail**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/RunScriptTemplateTests \
  -only-testing:AlasTests/RunScriptCreationTests test
```

Expected: FAIL because the new presentation, creator, error, and template overload do not exist.

- [ ] **Step 4: Implement exit-aware templates and creation primitives**

Change `RunScriptOnExit` to support use as a segmented-control identifier:

```swift
enum RunScriptOnExit: String, Sendable, Hashable {
    case keep
    case close
}
```

Change the template API:

```swift
static func contents(
    name: String,
    onExit: RunScriptOnExit = .keep
) -> String {
    """
    #!/bin/zsh
    # alas-name: \(name)
    # alas-on-exit: \(onExit.rawValue)

    """
}
```

Create `Alas/Sources/RunScripts/RunScriptCreation.swift`:

```swift
import Foundation

struct RunScriptCreationPresentation: Identifiable, Equatable {
    let id: UUID
    let scope: RunScriptScope
    let projectId: String
    let worktreeId: String
    let repositoryName: String

    init(
        id: UUID = UUID(),
        scope: RunScriptScope,
        projectId: String,
        worktreeId: String,
        repositoryName: String
    ) {
        self.id = id
        self.scope = scope
        self.projectId = projectId
        self.worktreeId = worktreeId
        self.repositoryName = repositoryName
    }

    var subtitle: String {
        switch scope {
        case .repo:
            "Create a script in .alas/scripts/ for \(repositoryName)."
        case .global:
            "Create a script available in every local worktree."
        }
    }
}

enum RunScriptCreationError: LocalizedError, Equatable {
    case emptyName
    case fileExists(String)
    case worktreeUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a script name."
        case .fileExists(let fileName):
            "A script named \"\(fileName)\" already exists."
        case .worktreeUnavailable:
            "The originating worktree is no longer available."
        }
    }
}

enum RunScriptCreator {
    static func normalizedName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func create(
        scope: RunScriptScope,
        name rawName: String,
        onExit: RunScriptOnExit,
        worktreeRoot: URL,
        globalDir: URL = Paths.runScriptsGlobalDir,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let name = normalizedName(rawName) else {
            throw RunScriptCreationError.emptyName
        }
        let directory = scope == .repo
            ? RunScriptStore.repoScriptsDir(worktreeRoot: worktreeRoot)
            : globalDir
        let url = directory.appendingPathComponent(RunScriptTemplate.fileName(for: name))

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw RunScriptCreationError.fileExists(url.lastPathComponent)
        }
        let data = Data(RunScriptTemplate.contents(name: name, onExit: onExit).utf8)
        try data.write(to: url, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
```

- [ ] **Step 5: Regenerate and run the focused tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/RunScriptTemplateTests \
  -only-testing:AlasTests/RunScriptCreationTests \
  -only-testing:AlasTests/RunScriptMetadataTests test
```

Expected: PASS.

- [ ] **Step 6: Commit the creation primitives**

```bash
rtk git add Alas/Sources/RunScripts/RunScript.swift \
  Alas/Sources/RunScripts/RunScriptTemplate.swift \
  Alas/Sources/RunScripts/RunScriptCreation.swift \
  AlasTests/RunScriptTemplateTests.swift \
  AlasTests/RunScriptCreationTests.swift \
  Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(run): model run script creation options"
```

---

### Task 3: Route script creation through AppState presentation state

**Files:**
- Modify: `Alas/Sources/App/AppState.swift:222-232`
- Modify: `Alas/Sources/App/AppState+RunScripts.swift:1-2,158-235`
- Create: `AlasTests/AppStateRunScriptCreationTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `RunScriptCreationPresentation`, `RunScriptCreator`, `RunScriptOnExit`, `AppState.worktree(withId:)`, `openFile`, and `TabsManager.openExternalEditor`.
- Produces:
  - `AppState.pendingRunScriptCreation: RunScriptCreationPresentation?`
  - `AppState.newRunScript(scope:in:)`
  - `AppState.createPendingRunScript(name:onExit:globalDir:) throws`
  - `AppState.cancelPendingRunScriptCreation()`

- [ ] **Step 1: Add failing AppState orchestration tests**

Create `AlasTests/AppStateRunScriptCreationTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

@MainActor
struct AppStateRunScriptCreationTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private func fixture() throws -> (AppState, ProjectConfig, Worktree, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = ProjectConfig(
            id: "project",
            name: "Alas",
            path: root.path,
            color: "blue",
            addedAt: Date()
        )
        let worktree = Worktree(
            id: "worktree",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: root,
            status: .clean,
            lastActivity: Date()
        )
        let state = AppState(store: MemoryStore())
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        return (state, project, worktree, root)
    }

    @Test func newScriptRecordsPendingPresentation() throws {
        let (state, project, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        state.newRunScript(scope: .repo, in: worktree)

        #expect(state.pendingRunScriptCreation?.scope == .repo)
        #expect(state.pendingRunScriptCreation?.projectId == project.id)
        #expect(state.pendingRunScriptCreation?.worktreeId == worktree.id)
        #expect(state.pendingRunScriptCreation?.repositoryName == project.name)
    }

    @Test func repoCreationWritesAndOpensRelativeEditor() throws {
        let (state, _, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        state.newRunScript(scope: .repo, in: worktree)

        try state.createPendingRunScript(name: " Dev Server ", onExit: .close)

        #expect(state.pendingRunScriptCreation == nil)
        let tab = try #require(state.tabs.activeTab(forWorktree: worktree.id))
        guard case .editor(let editor) = tab else {
            Issue.record("expected repo editor tab")
            return
        }
        #expect(editor.relativePath == ".alas/scripts/dev-server.sh")
        #expect(!editor.isExternal)
    }

    @Test func globalCreationUsesInjectedDirectoryAndOpensExternalEditor() throws {
        let (state, _, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let global = root.appendingPathComponent("global", isDirectory: true)
        state.newRunScript(scope: .global, in: worktree)

        try state.createPendingRunScript(
            name: "Build",
            onExit: .keep,
            globalDir: global
        )

        let tab = try #require(state.tabs.activeTab(forWorktree: worktree.id))
        guard case .editor(let editor) = tab else {
            Issue.record("expected global editor tab")
            return
        }
        #expect(editor.externalAbsolutePath == global.appendingPathComponent("build.sh").path)
        #expect(editor.externalEditable)
    }

    @Test func failurePreservesPendingPresentation() throws {
        let (state, project, worktree, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        state.pendingRunScriptCreation = RunScriptCreationPresentation(
            scope: .repo,
            projectId: project.id,
            worktreeId: "missing",
            repositoryName: project.name
        )

        #expect(throws: RunScriptCreationError.worktreeUnavailable) {
            try state.createPendingRunScript(name: "Build", onExit: .keep)
        }
        #expect(state.pendingRunScriptCreation != nil)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".alas/scripts/build.sh").path
        ))
    }
}
```

- [ ] **Step 2: Regenerate and verify orchestration tests fail**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/AppStateRunScriptCreationTests test
```

Expected: FAIL because pending presentation state and creation methods do not exist.

- [ ] **Step 3: Add pending state and replace the synchronous alert flow**

Add beside the run-script palette state in `AppState`:

```swift
var pendingRunScriptCreation: RunScriptCreationPresentation?
```

Remove `promptForRunScriptName()` and the filesystem-writing body from
`AppState+RunScripts.swift`. Remove `import AppKit` if no other AppKit symbol
remains.

Implement:

```swift
func newRunScript(scope: RunScriptScope, in worktree: Worktree) {
    if scope == .repo, worktree.path.isRemoteAlasPath {
        showFileActionError(
            title: "New Script Failed",
            message: "Run scripts are not supported on remote worktrees yet."
        )
        return
    }
    guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
        showFileActionError(
            title: "New Script Failed",
            message: "The originating project is no longer available."
        )
        return
    }
    pendingRunScriptCreation = RunScriptCreationPresentation(
        scope: scope,
        projectId: project.id,
        worktreeId: worktree.id,
        repositoryName: project.name
    )
}

func createPendingRunScript(
    name: String,
    onExit: RunScriptOnExit,
    globalDir: URL = Paths.runScriptsGlobalDir
) throws {
    guard let presentation = pendingRunScriptCreation,
          let worktree = worktree(withId: presentation.worktreeId),
          worktree.projectId == presentation.projectId
    else {
        throw RunScriptCreationError.worktreeUnavailable
    }

    let url = try RunScriptCreator.create(
        scope: presentation.scope,
        name: name,
        onExit: onExit,
        worktreeRoot: worktree.path,
        globalDir: globalDir
    )

    switch presentation.scope {
    case .repo:
        openFile(
            relativePath: "\(RunScriptStore.repoScriptsRelativeDir)/\(url.lastPathComponent)",
            worktreeId: worktree.id
        )
    case .global:
        _ = tabs.openExternalEditor(
            worktreeId: worktree.id,
            absoluteURL: url,
            revealLine: nil,
            revealCharacter: nil,
            editable: true
        )
    }
    pendingRunScriptCreation = nil
}

func cancelPendingRunScriptCreation() {
    pendingRunScriptCreation = nil
}
```

Keep `RunScriptPaletteEnvironment.newScript` routing to
`newRunScript(scope:in:)`; it now starts presentation instead of blocking on
`NSAlert`.

- [ ] **Step 4: Run focused AppState and run-script tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/AppStateRunScriptCreationTests \
  -only-testing:AlasTests/AppStateOverlayTests \
  -only-testing:AlasTests/RunScriptPaletteModelTests \
  -only-testing:AlasTests/RunScriptCreationTests test
```

Expected: PASS. On failure, pending presentation remains non-`nil`; on success,
the correct editor tab opens and pending state clears.

- [ ] **Step 5: Commit AppState orchestration**

```bash
rtk git add Alas/Sources/App/AppState.swift \
  Alas/Sources/App/AppState+RunScripts.swift \
  AlasTests/AppStateRunScriptCreationTests.swift \
  Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(run): present run script creation state"
```

---

### Task 4: Build and present the styled new-run-script sheet

**Files:**
- Create: `Alas/Sources/RunScripts/NewRunScriptDialog.swift`
- Modify: `Alas/Sources/App/RootView.swift:325-360`
- Modify: `AlasTests/TouchTargetSmokeTests.swift`
- Regenerate: `Alas.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DialogContainer`, `DialogField`, `AlasField`, `AlasSegmentedControl`, `RunScriptCreationPresentation`, and the Task 3 `AppState` methods.
- Produces:
  - `NewRunScriptDialog`
  - `NewRunScriptDialog.defaultOnExit == .keep`
  - `NewRunScriptDialog.canCreate(name:) -> Bool`

- [ ] **Step 1: Add failing dialog-state and rendering tests**

Append to `TouchTargetSmokeTests`:

```swift
@Test func newRunScriptDialogDefaultsAndValidationMatchDesign() {
    #expect(NewRunScriptDialog.defaultOnExit == .keep)
    #expect(!NewRunScriptDialog.canCreate(name: " \n"))
    #expect(NewRunScriptDialog.canCreate(name: "Dev Server"))
}

@Test func newRunScriptDialogRendersWithoutCrashing() {
    let state = AppState()
    let presentation = RunScriptCreationPresentation(
        scope: .repo,
        projectId: "project",
        worktreeId: "worktree",
        repositoryName: "Alas"
    )
    let view = NewRunScriptDialog(state: state, presentation: presentation)
        .environment(\.theme, currentTheme())
    let controller = NSHostingController(rootView: view)

    controller.view.layoutSubtreeIfNeeded()

    #expect(controller.view.fittingSize.width == DialogContainerLayout.defaultWidth)
    #expect(controller.view.fittingSize.height > 0)
}
```

- [ ] **Step 2: Regenerate and verify the dialog tests fail**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/TouchTargetSmokeTests/newRunScriptDialogDefaultsAndValidationMatchDesign \
  -only-testing:AlasTests/TouchTargetSmokeTests/newRunScriptDialogRendersWithoutCrashing test
```

Expected: FAIL because `NewRunScriptDialog` does not exist.

- [ ] **Step 3: Implement the SwiftUI sheet**

Create `Alas/Sources/RunScripts/NewRunScriptDialog.swift`:

```swift
import SwiftUI

struct NewRunScriptDialog: View {
    static let defaultOnExit = RunScriptOnExit.keep

    @Bindable var state: AppState
    let presentation: RunScriptCreationPresentation

    @State private var name = ""
    @State private var onExit = Self.defaultOnExit
    @State private var errorMessage: String?
    @Environment(\.theme) private var theme

    var body: some View {
        DialogContainer(
            title: "New run script",
            subtitle: presentation.subtitle,
            content: {
                DialogField(label: "Script name") {
                    AlasField(
                        text: $name,
                        placeholder: "Dev Server",
                        focusOnAppear: true,
                        onSubmit: submit
                    )
                }
                DialogField(label: "When script exits") {
                    HStack(spacing: 0) {
                        AlasSegmentedControl(
                            selection: onExit,
                            options: [
                                AlasSegmentedOption(id: .keep, label: "Keep pane open"),
                                AlasSegmentedOption(id: .close, label: "Close pane"),
                            ],
                            onSelect: {
                                onExit = $0
                                errorMessage = nil
                            }
                        )
                        Spacer(minLength: 0)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: "Create script",
            confirmStyle: .primary,
            onCancel: state.cancelPendingRunScriptCreation,
            onConfirm: submit,
            confirmEnabled: Self.canCreate(name: name)
        )
        .onChange(of: name) { _, _ in
            errorMessage = nil
        }
    }

    nonisolated static func canCreate(name: String) -> Bool {
        RunScriptCreator.normalizedName(name) != nil
    }

    private func submit() {
        guard Self.canCreate(name: name) else { return }
        do {
            try state.createPendingRunScript(name: name, onExit: onExit)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Present the sheet from RootView**

After the new-worktree `.sheet(item:)` in `RootPresentationHandlers`, add:

```swift
.sheet(item: $state.pendingRunScriptCreation) { presentation in
    NewRunScriptDialog(
        state: state,
        presentation: presentation
    )
}
```

Do not add another local `@State` copy. `AppState.pendingRunScriptCreation` is
the single presentation source, so cancellation, successful creation, and
programmatic teardown all dismiss the same sheet.

- [ ] **Step 5: Regenerate and run all affected tests**

Run:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing:AlasTests/TouchTargetSmokeTests \
  -only-testing:AlasTests/NewWorktreeDialogTests \
  -only-testing:AlasTests/AppStateRunScriptCreationTests \
  -only-testing:AlasTests/RunScriptCreationTests \
  -only-testing:AlasTests/RunScriptTemplateTests \
  -only-testing:AlasTests/RunScriptMetadataTests \
  -only-testing:AlasTests/RunScriptPaletteModelTests test
```

Expected: PASS.

- [ ] **Step 6: Commit the dialog**

```bash
rtk git add Alas/Sources/RunScripts/NewRunScriptDialog.swift \
  Alas/Sources/App/RootView.swift \
  AlasTests/TouchTargetSmokeTests.swift \
  Alas.xcodeproj/project.pbxproj
rtk git commit -m "feat(run): add styled new script dialog"
```

---

### Task 5: Perform repository-required verification

**Files:**
- Verify only; no source changes expected.

**Interfaces:**
- Consumes: the completed Tasks 1-4.
- Produces: evidence that generated project state, the macOS build, and the full test suite are green.

- [ ] **Step 1: Confirm generated project state is clean**

Run:

```bash
rtk xcodegen
rtk git diff --exit-code -- project.yml Alas.xcodeproj/project.pbxproj
```

Expected: both commands exit 0 with no diff.

- [ ] **Step 2: Run the quiet macOS build**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: exit 0 with no build errors.

- [ ] **Step 3: Run the full macOS test suite**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Inspect final scope and history**

Run:

```bash
rtk git status --short
rtk git log --oneline origin/main..HEAD
rtk git diff --stat origin/main...HEAD
```

Expected: the worktree is clean; history contains the design and plan commits
plus the four focused implementation commits; the diff is limited to the shared
segmented control, run-script creation flow, dialog, tests, generated project,
and approved design/plan documents.
