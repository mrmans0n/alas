# Project Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add project icon customization with Letter, Symbol, Emoji, and Image modes, including GitHub/GitLab avatar presets and shared rendering across project identity surfaces.

**Architecture:** Add `ProjectIcon` as a structured value on `ProjectConfig`, keep legacy `color` mirrored for compatibility, and route all project identity rendering through a reusable `ProjectIconView`. Keep file/image storage and avatar fetching in focused helpers so `ProjectsManager` remains a persistence/state coordinator, not a network or image-decoding owner.

**Tech Stack:** Swift 5.9, SwiftUI for macOS 15, Swift Testing, AppKit `NSOpenPanel`/`NSImage`, ImageIO/CryptoKit for image staging, existing `CodeHostRemoteDetector`.

---

## File Structure

- Create `Alas/Sources/Persistence/ProjectIcon.swift`: persisted icon model, sanitization helpers, defaults, and fallback label/color behavior.
- Modify `Alas/Sources/Persistence/ProjectConfig.swift`: add `icon`, tolerant decode, encode mirror from `icon.color` to legacy `color`.
- Modify `Alas/Sources/App/ProjectsManager.swift`: change `ProjectUpdate` and add/update project paths to carry `ProjectIcon`.
- Modify `Alas/Sources/App/AppState.swift`: thread structured project icons through add/update methods.
- Create `Alas/Sources/Sidebar/ProjectIconView.swift`: shared SwiftUI renderer and stable sizing.
- Modify `Alas/Sources/Sidebar/RepoGroupView.swift`: replace `RepoDot`.
- Modify `Alas/Sources/Dialogs/RepoSelector/RepoSelectorRowView.swift`: replace `RepoDot`.
- Modify `Alas/Sources/Dialogs/ProjectPicker.swift`: replace small color dots.
- Create `Alas/Sources/Dialogs/ProjectIconImageStaging.swift`: managed image copy/validation helper.
- Create `Alas/Sources/Dialogs/ProjectAvatarPresetProvider.swift`: remote detection and non-blocking avatar fetch support.
- Modify `Alas/Sources/Persistence/Paths.swift`: add `projectIconsRoot` and per-project directory helper.
- Modify `Alas/Sources/Dialogs/NewProjectDialog.swift`: add Icon section, draft state, controls, image import, and avatar preset.
- Add tests:
  - `AlasTests/ProjectIconTests.swift`
  - `AlasTests/ProjectIconImageStagingTests.swift`
  - `AlasTests/ProjectAvatarPresetProviderTests.swift`
  - extend `AlasTests/ProjectConfigTests.swift`
  - extend `AlasTests/ProjectsManagerTests.swift`
  - extend `AlasTests/RepoGroupViewLayoutTests.swift`
  - extend `AlasTests/ProjectPickerTests.swift`

## Verification Commands

Use these after relevant tasks:

```bash
rtk xcodegen
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectIconTests -quiet test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectIconImageStagingTests -quiet test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectAvatarPresetProviderTests -quiet test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectConfigTests -quiet test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectsManagerTests -quiet test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RepoGroupViewLayoutTests -quiet test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectPickerTests -quiet test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Run the full test command from `AGENTS.md` before final handoff:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

---

### Task 1: Persisted ProjectIcon Model

**Files:**
- Create: `Alas/Sources/Persistence/ProjectIcon.swift`
- Modify: `Alas/Sources/Persistence/ProjectConfig.swift`
- Test: `AlasTests/ProjectIconTests.swift`
- Test: `AlasTests/ProjectConfigTests.swift`

- [ ] **Step 1: Write model tests**

Create `AlasTests/ProjectIconTests.swift`:

```swift
import Testing
@testable import Alas

struct ProjectIconTests {
    @Test func defaultIconUsesLetterModeAndColor() {
        let icon = ProjectIcon.default(color: "#123456")

        #expect(icon.mode == .letter)
        #expect(icon.color == "#123456")
        #expect(icon.label == nil)
        #expect(icon.symbolName == nil)
        #expect(icon.emoji == nil)
        #expect(icon.imageAssetName == nil)
    }

    @Test func fallbackLabelUsesLastPathComponentInitial() {
        #expect(ProjectIcon.fallbackLabel(projectName: "mrmans0n/alas") == "A")
        #expect(ProjectIcon.fallbackLabel(projectName: "  ") == "?")
    }

    @Test func sanitizedLabelClampsToTwoCharacters() {
        #expect(ProjectIcon.sanitizedLabel("abc") == "AB")
        #expect(ProjectIcon.sanitizedLabel("z") == "Z")
        #expect(ProjectIcon.sanitizedLabel("  ") == nil)
    }

    @Test func sanitizedColorRequiresSixDigitHex() {
        #expect(ProjectIcon.sanitizedColor("#aabbcc") == "#aabbcc")
        #expect(ProjectIcon.sanitizedColor("AABBCC") == "#AABBCC")
        #expect(ProjectIcon.sanitizedColor("bad") == ProjectIcon.defaultColor)
        #expect(ProjectIcon.sanitizedColor("#12345g") == ProjectIcon.defaultColor)
    }
}
```

Extend `AlasTests/ProjectConfigTests.swift` with:

```swift
extension ProjectConfigTests {
    @Test func decodingOlderProjectWithoutIconSynthesizesLetterIcon() throws {
        let json = """
        {
          "version": 1,
          "projects": [{
            "id": "abc",
            "name": "alpha",
            "path": "/tmp/alpha",
            "color": "#5fb7c4",
            "addedAt": 0
          }]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let file = try decoder.decode(ProjectsFile.self, from: json)

        #expect(file.projects[0].icon.mode == .letter)
        #expect(file.projects[0].icon.color == "#5fb7c4")
        #expect(file.projects[0].icon.label == nil)
    }

    @Test func roundTripPreservesProjectIconAndMirrorsLegacyColor() throws {
        let project = ProjectConfig(
            id: "abc",
            name: "alpha",
            path: "/tmp/alpha",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0),
            icon: ProjectIcon(
                mode: .symbol,
                color: "#112233",
                symbolName: "terminal"
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(ProjectsFile(projects: [project]))

        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"color\":\"#112233\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(ProjectsFile.self, from: data)
        #expect(decoded.projects[0].color == "#112233")
        #expect(decoded.projects[0].icon.mode == .symbol)
        #expect(decoded.projects[0].icon.symbolName == "terminal")
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectIconTests -only-testing:AlasTests/ProjectConfigTests -quiet test
```

Expected: FAIL because `ProjectIcon` and `ProjectConfig.icon` do not exist.

- [ ] **Step 3: Add `ProjectIcon`**

Create `Alas/Sources/Persistence/ProjectIcon.swift`:

```swift
import Foundation

struct ProjectIcon: Codable, Equatable {
    enum Mode: String, Codable, Equatable, CaseIterable {
        case letter
        case symbol
        case emoji
        case image
    }

    static let defaultColor = "#5fb7c4"

    var mode: Mode
    var color: String
    var label: String?
    var symbolName: String?
    var emoji: String?
    var imageAssetName: String?

    init(
        mode: Mode,
        color: String,
        label: String? = nil,
        symbolName: String? = nil,
        emoji: String? = nil,
        imageAssetName: String? = nil
    ) {
        self.mode = mode
        self.color = Self.sanitizedColor(color)
        self.label = Self.sanitizedLabel(label)
        self.symbolName = Self.sanitizedNonEmpty(symbolName)
        self.emoji = Self.sanitizedNonEmpty(emoji)
        self.imageAssetName = Self.sanitizedNonEmpty(imageAssetName)
    }

    static func `default`(color: String = defaultColor) -> ProjectIcon {
        ProjectIcon(mode: .letter, color: color)
    }

    static func fallbackLabel(projectName: String) -> String {
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = name.split(separator: "/").last.map(String.init) ?? name
        guard let first = tail.first else { return "?" }
        return String(first).uppercased()
    }

    static func sanitizedLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(2)).uppercased()
    }

    static func sanitizedColor(_ raw: String) -> String {
        let value = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard value.count == 6,
              value.allSatisfy({ $0.isHexDigit })
        else {
            return defaultColor
        }
        return "#\(value)"
    }

    static func sanitizedNonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
```

- [ ] **Step 4: Add `icon` to `ProjectConfig` with tolerant decode**

In `Alas/Sources/Persistence/ProjectConfig.swift`, add `var icon: ProjectIcon` directly after `var color: String`, and add `icon` to `CodingKeys` between `color` and `addedAt`.

Update the initializer signature:

```swift
init(
    id: String,
    name: String,
    path: String,
    color: String,
    addedAt: Date,
    icon: ProjectIcon? = nil,
    hiddenWorktreePaths: [String] = [],
    worktreeOrder: [String] = [],
    worktreeOrderIsManual: Bool = false,
    startupScripts: ProjectStartupScripts = .defaults,
    worktreeOpenAfterCreate: Bool? = nil,
    worktreeDefaultLauncherMode: AppConfig.LauncherMode? = nil
) {
    self.id = id
    self.name = name
    self.path = path
    self.icon = icon ?? ProjectIcon.default(color: color)
    self.color = self.icon.color
    self.addedAt = addedAt
    self.hiddenWorktreePaths = hiddenWorktreePaths
    self.worktreeOrder = worktreeOrder
    self.worktreeOrderIsManual = worktreeOrderIsManual
    self.startupScripts = startupScripts
    self.worktreeOpenAfterCreate = worktreeOpenAfterCreate
    self.worktreeDefaultLauncherMode = worktreeDefaultLauncherMode
}
```

Update decode:

```swift
let decodedColor = try c.decode(String.self, forKey: .color)
let decodedIcon = (try? c.decode(ProjectIcon.self, forKey: .icon))
    ?? ProjectIcon.default(color: decodedColor)
icon = decodedIcon
color = decodedIcon.color
```

Add a custom `encode(to:)` so legacy `color` mirrors `icon.color`:

```swift
func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(path, forKey: .path)
    try c.encode(icon.color, forKey: .color)
    try c.encode(icon, forKey: .icon)
    try c.encode(addedAt, forKey: .addedAt)
    try c.encode(hiddenWorktreePaths, forKey: .hiddenWorktreePaths)
    try c.encode(worktreeOrder, forKey: .worktreeOrder)
    try c.encode(worktreeOrderIsManual, forKey: .worktreeOrderIsManual)
    try c.encode(startupScripts, forKey: .startupScripts)
    try c.encodeIfPresent(worktreeOpenAfterCreate, forKey: .worktreeOpenAfterCreate)
    try c.encodeIfPresent(worktreeDefaultLauncherMode, forKey: .worktreeDefaultLauncherMode)
}
```

- [ ] **Step 5: Run tests and verify pass**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectIconTests -only-testing:AlasTests/ProjectConfigTests -quiet test
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
rtk git add Alas/Sources/Persistence/ProjectIcon.swift Alas/Sources/Persistence/ProjectConfig.swift AlasTests/ProjectIconTests.swift AlasTests/ProjectConfigTests.swift
rtk git commit -m "feat: add project icon model"
```

---

### Task 2: ProjectsManager and AppState Icon Plumbing

**Files:**
- Modify: `Alas/Sources/App/ProjectsManager.swift`
- Modify: `Alas/Sources/App/AppState.swift`
- Test: `AlasTests/ProjectsManagerTests.swift`

- [ ] **Step 1: Write update/add tests**

Update `AlasTests/ProjectsManagerTests.swift`:

```swift
@Test func addProjectUsesProvidedIconAndMirrorsColor() async throws {
    let repo = try await makeRepo(name: "lambda")
    defer { try? FileManager.default.removeItem(at: repo) }
    let mgr = ProjectsManager(persistedProjects: [])
    let icon = ProjectIcon(mode: .emoji, color: "#112233", emoji: "🚀")

    let project = try await mgr.addProject(path: repo, displayName: "lambda", icon: icon)

    #expect(project.icon == icon)
    #expect(project.color == "#112233")
}
```

Replace the body of `updateProjectUpdatesNameAndColorOnly` so it asserts icon preservation and update:

```swift
@Test func updateProjectUpdatesNameIconAndStartupScriptsOnly() {
    let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let project = ProjectConfig(
        id: "project-1",
        name: "Before",
        path: "/tmp/before",
        color: "#5fb7c4",
        addedAt: addedAt,
        hiddenWorktreePaths: ["/tmp/before/.worktree"]
    )
    let other = ProjectConfig(
        id: "project-2",
        name: "Other",
        path: "/tmp/other",
        color: "#9789c7",
        addedAt: addedAt.addingTimeInterval(1),
        hiddenWorktreePaths: []
    )
    let mgr = ProjectsManager(persistedProjects: [project, other])
    let icon = ProjectIcon(mode: .symbol, color: "#d77b88", symbolName: "terminal")

    mgr.updateProject(
        id: project.id,
        update: ProjectUpdate(name: "After", icon: icon)
    )

    #expect(mgr.projects[0].id == project.id)
    #expect(mgr.projects[0].name == "After")
    #expect(mgr.projects[0].path == project.path)
    #expect(mgr.projects[0].icon == icon)
    #expect(mgr.projects[0].color == "#d77b88")
    #expect(mgr.projects[0].addedAt == project.addedAt)
    #expect(mgr.projects[0].hiddenWorktreePaths == project.hiddenWorktreePaths)
    #expect(mgr.projects[0].startupScripts == .defaults)
    #expect(mgr.projects[1] == other)

    mgr.updateProject(
        id: "missing",
        update: ProjectUpdate(name: "Ignored", icon: ProjectIcon.default(color: "#7fb978"))
    )

    #expect(mgr.projects[0].name == "After")
    #expect(mgr.projects[0].icon == icon)
    #expect(mgr.projects[1] == other)
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectsManagerTests -quiet test
```

Expected: FAIL because `ProjectUpdate.icon` and `addProject(... icon:)` do not exist.

- [ ] **Step 3: Update manager APIs**

Modify `Alas/Sources/App/ProjectsManager.swift`:

```swift
struct ProjectUpdate: Equatable {
    var name: String
    var icon: ProjectIcon
    var startupScripts: ProjectStartupScripts = .defaults
}
```

Replace `addProject(path:displayName:color:)` with:

```swift
func addProject(path: URL, displayName: String, icon: ProjectIcon) async throws -> ProjectConfig {
    let isRepo = try await git.isGitRepository(path)
    guard isRepo else {
        throw NSError(domain: "ProjectsManager", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Not a git repository: \(path.path)"])
    }
    let project = ProjectConfig(
        id: UUID().uuidString,
        name: displayName,
        path: path.path,
        color: icon.color,
        addedAt: Date(),
        icon: icon
    )
    projects.append(project)
    return project
}
```

Update `updateProject`:

```swift
func updateProject(id: String, update: ProjectUpdate) {
    guard let idx = projects.firstIndex(where: { $0.id == id }) else { return }
    projects[idx].name = update.name
    projects[idx].icon = update.icon
    projects[idx].color = update.icon.color
    projects[idx].startupScripts = update.startupScripts
}
```

Update the known direct call sites:

```swift
let project = try await mgr.addProject(
    path: repo,
    displayName: "alpha",
    icon: ProjectIcon.default(color: "#5fb7c4")
)
```

```swift
ProjectUpdate(
    name: "After",
    icon: ProjectIcon.default(color: "#d77b88"),
    startupScripts: scripts
)
```

Use this search to find any missed API calls:

```bash
rtk rg -n "addProject\\(|ProjectUpdate\\(" Alas/Sources AlasTests
```

- [ ] **Step 4: Update AppState API signatures**

Modify `Alas/Sources/App/AppState.swift`:

```swift
func addProject(path: URL, displayName: String, icon: ProjectIcon) async throws {
    let project = try await projectsManager.addProject(path: path, displayName: displayName, icon: icon)
    spacesManager.addProject(project.id, toSpace: spacesManager.activeSpaceId)
    saveProjects()
    saveSpaces()
    if await projectsManager.refreshAll() {
        saveProjects()
    }
    startProjectGitWatcher(for: project)
}
```

Modify update:

```swift
func updateProject(id: String, name: String, icon: ProjectIcon, startupScripts: ProjectStartupScripts) {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return }

    projectsManager.updateProject(
        id: id,
        update: ProjectUpdate(
            name: trimmedName,
            icon: icon,
            startupScripts: startupScripts
        )
    )
    saveProjects()
}
```

- [ ] **Step 5: Run tests and compile check**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectsManagerTests -quiet test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
rtk git add Alas/Sources/App/ProjectsManager.swift Alas/Sources/App/AppState.swift AlasTests/ProjectsManagerTests.swift
rtk git commit -m "feat: thread project icons through project state"
```

---

### Task 3: Shared ProjectIconView Renderer

**Files:**
- Create: `Alas/Sources/Sidebar/ProjectIconView.swift`
- Modify: `Alas/Sources/Sidebar/RepoGroupView.swift`
- Modify: `Alas/Sources/Dialogs/RepoSelector/RepoSelectorRowView.swift`
- Modify: `Alas/Sources/Dialogs/ProjectPicker.swift`
- Test: `AlasTests/RepoGroupViewLayoutTests.swift`
- Test: `AlasTests/ProjectPickerTests.swift`

- [ ] **Step 1: Add renderer layout tests**

Extend `AlasTests/RepoGroupViewLayoutTests.swift` with:

```swift
@Test func projectIconSymbolHeaderAnchorDoesNotShiftWhenExpanded() throws {
    let collapsedX = try repoIconMinX(collapsed: true, icon: ProjectIcon(mode: .symbol, color: "#ff0000", symbolName: "terminal"))
    let expandedX = try repoIconMinX(collapsed: false, icon: ProjectIcon(mode: .symbol, color: "#ff0000", symbolName: "terminal"))

    #expect(collapsedX == expandedX)
}
```

Refactor the helper to accept `icon`:

```swift
private func repoIconMinX(collapsed: Bool, icon: ProjectIcon = ProjectIcon.default(color: "#ff0000")) throws -> Int {
    let project = ProjectConfig(
        id: "project-1",
        name: "Sample",
        path: "/tmp/sample",
        color: icon.color,
        addedAt: Date(timeIntervalSince1970: 0),
        icon: icon
    )
    let view = RepoGroupView(
        project: project,
        worktrees: worktrees,
        collapsed: .constant(collapsed),
        selectedWorktreeId: nil,
        isMain: { _ in false },
        operationState: { _ in nil },
        harnessSummary: { _ in nil },
        onSelect: { _ in },
        onNewWorktree: {},
        onEditProject: {},
        onRemoveProject: {},
        onResetSort: {},
        spaces: [],
        activeSpaceId: "",
        isProjectInSpace: { _ in false },
        canRemoveFromSpace: { _ in true },
        onToggleSpaceMembership: { _ in },
        onOpenTerminal: { _ in },
        onCopyPath: { _ in },
        onCopyBranch: { _ in },
        onRevealInFinder: { _ in },
        onArchive: { _ in },
        onDelete: { _ in },
        onDeleteKeepBranch: { _ in },
        showKeepBranchOption: false,
        onActivateHarness: { _ in },
        onCopyError: { _ in },
        onRetryCreate: { _ in },
        onRetryDelete: { _ in },
        onRemoveFailed: { _ in },
        onDropWorktree: { _, _ in },
        onDropProject: { _, _ in }
    )
    .environment(\.theme, try ThemeStore().current)

    let controller = NSHostingController(rootView: view)
    controller.view.frame = NSRect(x: 0, y: 0, width: 260, height: collapsed ? 40 : 100)
    controller.view.layoutSubtreeIfNeeded()

    let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
    controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)

    var minX: Int?
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.redComponent > 0.8,
               color.greenComponent < 0.2,
               color.blueComponent < 0.2,
               color.alphaComponent > 0.5 {
                minX = min(minX ?? x, x)
            }
        }
    }

    return try #require(minX)
}
```

Update `repoHeaderAnchorDoesNotShiftWhenExpanded` to call `repoIconMinX`.

Extend `AlasTests/ProjectPickerTests.swift` with a pure helper test after Task 3 adds it:

```swift
@Test func projectIconAccessibilityLabelNamesModeAndProject() {
    let project = ProjectConfig(
        id: "p1",
        name: "Alpha",
        path: "/tmp/alpha",
        color: "#5fb7c4",
        addedAt: Date(timeIntervalSince1970: 0),
        icon: ProjectIcon(mode: .emoji, color: "#5fb7c4", emoji: "🚀")
    )

    #expect(ProjectIconView.accessibilityLabel(project: project) == "Alpha project icon")
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RepoGroupViewLayoutTests -only-testing:AlasTests/ProjectPickerTests -quiet test
```

Expected: FAIL because `ProjectIconView` does not exist.

- [ ] **Step 3: Implement renderer**

Create `Alas/Sources/Sidebar/ProjectIconView.swift`:

```swift
import SwiftUI
import AppKit

struct ProjectIconView: View {
    enum Size {
        case sidebar
        case picker
        case dialog

        var dimension: CGFloat {
            switch self {
            case .sidebar: 16
            case .picker: 18
            case .dialog: 72
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .sidebar: 4
            case .picker: 5
            case .dialog: 18
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .sidebar: 9.5
            case .picker: 10.5
            case .dialog: 26
            }
        }
    }

    let icon: ProjectIcon
    let fallbackName: String
    var size: Size = .sidebar

    var body: some View {
        content
            .frame(width: size.dimension, height: size.dimension)
            .clipShape(RoundedRectangle(cornerRadius: size.cornerRadius))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch icon.mode {
        case .letter:
            labelView(ProjectIcon.sanitizedLabel(icon.label) ?? ProjectIcon.fallbackLabel(projectName: fallbackName))
        case .symbol:
            if let symbolName = icon.symbolName {
                symbolView(symbolName)
            } else {
                labelView(ProjectIcon.fallbackLabel(projectName: fallbackName))
            }
        case .emoji:
            if let emoji = icon.emoji, !emoji.isEmpty {
                emojiView(emoji)
            } else {
                labelView(ProjectIcon.fallbackLabel(projectName: fallbackName))
            }
        case .image:
            if let image = loadImage() {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.dimension, height: size.dimension)
            } else {
                labelView(ProjectIcon.fallbackLabel(projectName: fallbackName))
            }
        }
    }

    private func labelView(_ label: String) -> some View {
        Text(label)
            .font(.system(size: size.fontSize, weight: .bold))
            .foregroundColor(.white)
            .minimumScaleFactor(0.65)
            .lineLimit(1)
            .frame(width: size.dimension, height: size.dimension)
            .background(Color(hex: icon.color))
    }

    @ViewBuilder
    private func symbolView(_ name: String) -> some View {
        ZStack {
            Color(hex: icon.color)
            Icon(name: name, size: size.fontSize + 2, color: .white)
        }
    }

    private func emojiView(_ emoji: String) -> some View {
        Text(emoji)
            .font(.system(size: size.fontSize + 2))
            .minimumScaleFactor(0.55)
            .lineLimit(1)
            .frame(width: size.dimension, height: size.dimension)
            .background(Color(hex: icon.color))
    }

    private func loadImage() -> NSImage? {
        guard let imageAssetName = icon.imageAssetName else { return nil }
        return NSImage(contentsOfFile: imageAssetName)
    }

    static func accessibilityLabel(project: ProjectConfig) -> String {
        "\(project.name) project icon"
    }
}
```

- [ ] **Step 4: Replace known project identity surfaces**

In `Alas/Sources/Sidebar/RepoGroupView.swift`, replace:

```swift
RepoDot(color: project.color, letter: letter)
```

with:

```swift
ProjectIconView(icon: project.icon, fallbackName: project.name, size: .sidebar)
    .accessibilityLabel(ProjectIconView.accessibilityLabel(project: project))
```

Remove the now-unused `letter` computed property if no call site remains.

In `Alas/Sources/Dialogs/RepoSelector/RepoSelectorRowView.swift`, replace:

```swift
RepoDot(color: project.color, letter: String(project.name.prefix(1)).uppercased())
```

with:

```swift
ProjectIconView(icon: project.icon, fallbackName: project.name, size: .sidebar)
```

In `Alas/Sources/Dialogs/ProjectPicker.swift`, replace both small color `Circle()` snippets with:

```swift
ProjectIconView(icon: project.icon, fallbackName: project.name, size: .picker)
```

- [ ] **Step 5: Run focused renderer tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/RepoGroupViewLayoutTests -only-testing:AlasTests/ProjectPickerTests -quiet test
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
rtk git add Alas/Sources/Sidebar/ProjectIconView.swift Alas/Sources/Sidebar/RepoGroupView.swift Alas/Sources/Dialogs/RepoSelector/RepoSelectorRowView.swift Alas/Sources/Dialogs/ProjectPicker.swift AlasTests/RepoGroupViewLayoutTests.swift AlasTests/ProjectPickerTests.swift
rtk git commit -m "feat: render shared project icons"
```

---

### Task 4: Managed Image Staging

**Files:**
- Modify: `Alas/Sources/Persistence/Paths.swift`
- Create: `Alas/Sources/Dialogs/ProjectIconImageStaging.swift`
- Modify: `Alas/Sources/Sidebar/ProjectIconView.swift`
- Test: `AlasTests/ProjectIconImageStagingTests.swift`

- [ ] **Step 1: Write staging tests**

Create `AlasTests/ProjectIconImageStagingTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

struct ProjectIconImageStagingTests {
    @Test func pngDataStagesUnderProjectDirectory() throws {
        let data = Self.onePixelPNG
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-icons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let staged = try ProjectIconImageStaging.stage(
            data: data,
            projectId: "project-1",
            root: root
        )

        #expect(staged.assetName.hasSuffix(".png"))
        #expect(staged.url.path.contains("/project-1/"))
        #expect(FileManager.default.fileExists(atPath: staged.url.path))
        #expect(try Data(contentsOf: staged.url) == data)
    }

    @Test func unsupportedDataThrows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-icons-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: ProjectIconImageStaging.StagingError.unsupportedFormat) {
            try ProjectIconImageStaging.stage(
                data: Data("not an image".utf8),
                projectId: "project-1",
                root: root
            )
        }
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
    )!
}
```

- [ ] **Step 2: Run test and verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectIconImageStagingTests -quiet test
```

Expected: FAIL because `ProjectIconImageStaging` does not exist.

- [ ] **Step 3: Add project icon paths**

Modify `Alas/Sources/Persistence/Paths.swift`:

```swift
extension Paths {
    static var projectIconsRoot: URL {
        appSupportRoot.appendingPathComponent("project-icons", isDirectory: true)
    }

    static func projectIconsDir(forProjectId id: String) -> URL {
        projectIconsRoot.appendingPathComponent(id, isDirectory: true)
    }
}
```

- [ ] **Step 4: Implement staging helper**

Create `Alas/Sources/Dialogs/ProjectIconImageStaging.swift`:

```swift
import Foundation
import CryptoKit

enum ProjectIconImageStaging {
    struct Staged: Equatable {
        let assetName: String
        let url: URL
    }

    enum StagingError: Error, Equatable {
        case unsupportedFormat
        case tooLarge
        case writeFailed
    }

    static let maxBytes = 10 * 1024 * 1024

    static func stage(data: Data, projectId: String, root: URL = Paths.projectIconsRoot) throws -> Staged {
        guard data.count <= maxBytes else { throw StagingError.tooLarge }
        guard let ext = fileExtension(for: data) else { throw StagingError.unsupportedFormat }

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let dir = root.appendingPathComponent(projectId, isDirectory: true)
        let filename = "\(hash).\(ext)"
        let url = dir.appendingPathComponent(filename)

        do {
            try Paths.ensureDirectoryExists(dir)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
            return Staged(assetName: "\(projectId)/\(filename)", url: url)
        } catch {
            throw StagingError.writeFailed
        }
    }

    static func url(for assetName: String, root: URL = Paths.projectIconsRoot) -> URL {
        root.appendingPathComponent(assetName)
    }

    static func fileExtension(for data: Data) -> String? {
        let b = [UInt8](data.prefix(16))
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "gif" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        return nil
    }
}

extension ProjectIconImageStaging.StagingError {
    var userMessage: String {
        switch self {
        case .unsupportedFormat: "That image format isn't supported (use PNG, JPEG, GIF, or WebP)."
        case .tooLarge: "That image is too large (max 10 MB)."
        case .writeFailed: "Couldn't save that project icon. Please try again."
        }
    }
}
```

- [ ] **Step 5: Resolve image assets in renderer**

Modify `ProjectIconView.loadImage()`:

```swift
private func loadImage() -> NSImage? {
    guard let imageAssetName = icon.imageAssetName else { return nil }
    let url = ProjectIconImageStaging.url(for: imageAssetName)
    return NSImage(contentsOf: url)
}
```

- [ ] **Step 6: Run staging tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectIconImageStagingTests -quiet test
```

Expected: PASS.

- [ ] **Step 7: Commit**

Run:

```bash
rtk git add Alas/Sources/Persistence/Paths.swift Alas/Sources/Dialogs/ProjectIconImageStaging.swift Alas/Sources/Sidebar/ProjectIconView.swift AlasTests/ProjectIconImageStagingTests.swift
rtk git commit -m "feat: stage project icon images"
```

---

### Task 5: Avatar Preset Provider

**Files:**
- Create: `Alas/Sources/Dialogs/ProjectAvatarPresetProvider.swift`
- Test: `AlasTests/ProjectAvatarPresetProviderTests.swift`

- [ ] **Step 1: Write preset mapping tests**

Create `AlasTests/ProjectAvatarPresetProviderTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

struct ProjectAvatarPresetProviderTests {
    @Test func githubRemoteMapsToOwnerAvatarURL() throws {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )

        let candidate = try #require(ProjectAvatarPresetProvider.candidate(for: remote))
        #expect(candidate.label == "GitHub avatar: mrmans0n")
        #expect(candidate.url == URL(string: "https://github.com/mrmans0n.png?size=256")!)
    }

    @Test func gitlabRemoteMapsToNamespaceAvatarURL() throws {
        let remote = CodeHostRemote(
            kind: .gitlab,
            host: "gitlab.com",
            owner: "group/subgroup",
            repository: "repo",
            remoteName: "origin",
            webURL: URL(string: "https://gitlab.com/group/subgroup/repo")!
        )

        let candidate = try #require(ProjectAvatarPresetProvider.candidate(for: remote))
        #expect(candidate.label == "GitLab avatar: group/subgroup")
        #expect(candidate.url.absoluteString.contains("https://gitlab.com/api/v4/groups/"))
        #expect(candidate.url.absoluteString.contains("group%2Fsubgroup"))
    }
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectAvatarPresetProviderTests -quiet test
```

Expected: FAIL because `ProjectAvatarPresetProvider` does not exist.

- [ ] **Step 3: Implement provider**

Create `Alas/Sources/Dialogs/ProjectAvatarPresetProvider.swift`:

```swift
import Foundation

struct ProjectAvatarPreset: Equatable {
    let label: String
    let url: URL
}

protocol ProjectAvatarFetching {
    func data(from url: URL) async throws -> Data
}

struct URLSessionProjectAvatarFetcher: ProjectAvatarFetching {
    func data(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

enum ProjectAvatarPresetProvider {
    static func candidate(for remote: CodeHostRemote) -> ProjectAvatarPreset? {
        switch remote.kind {
        case .github:
            guard let url = URL(string: "https://\(remote.host)/\(remote.owner).png?size=256") else {
                return nil
            }
            return ProjectAvatarPreset(label: "GitHub avatar: \(remote.owner)", url: url)
        case .gitlab:
            let escaped = remote.owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
                .replacingOccurrences(of: "/", with: "%2F")
            guard let escaped,
                  let url = URL(string: "https://\(remote.host)/api/v4/groups/\(escaped)/avatar")
            else {
                return nil
            }
            return ProjectAvatarPreset(label: "GitLab avatar: \(remote.owner)", url: url)
        }
    }

    static func candidate(from remotes: [GitRemote]) -> ProjectAvatarPreset? {
        guard let remote = CodeHostRemoteDetector.detect(from: remotes) else { return nil }
        return candidate(for: remote)
    }

    static func fetch(_ preset: ProjectAvatarPreset, fetcher: ProjectAvatarFetching = URLSessionProjectAvatarFetcher()) async throws -> Data {
        try await fetcher.data(from: preset.url)
    }
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectAvatarPresetProviderTests -quiet test
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
rtk git add Alas/Sources/Dialogs/ProjectAvatarPresetProvider.swift AlasTests/ProjectAvatarPresetProviderTests.swift
rtk git commit -m "feat: derive project avatar presets"
```

---

### Task 6: Add/Edit Project Icon Editor UI

**Files:**
- Modify: `Alas/Sources/Dialogs/NewProjectDialog.swift`
- Test: existing dialog/model tests plus quiet build

- [ ] **Step 1: Add draft state**

In `ProjectDialog`, replace:

```swift
@State private var color: String = "#5fb7c4"
```

with:

```swift
@State private var iconMode: ProjectIcon.Mode = .letter
@State private var iconColor: String = ProjectIcon.defaultColor
@State private var iconLabel: String = ""
@State private var iconSymbolName: String = "folder"
@State private var iconEmoji: String = "🚀"
@State private var iconImageAssetName: String?
@State private var pendingIconStorageId = "pending-\(UUID().uuidString)"
@State private var avatarPreset: ProjectAvatarPreset?
@State private var avatarPresetData: Data?
@State private var avatarPresetLoading = false
@State private var avatarPresetError = false
```

Add:

```swift
private var draftIcon: ProjectIcon {
    ProjectIcon(
        mode: iconMode,
        color: iconColor,
        label: iconLabel,
        symbolName: iconSymbolName,
        emoji: iconEmoji,
        imageAssetName: iconImageAssetName
    )
}
```

- [ ] **Step 2: Replace Color field with Icon section**

In the dialog `content`, replace the `DialogField(label: "Color")` block with:

```swift
DialogField(label: "Icon") {
    projectIconSection
}
```

Add a `projectIconSection` view:

```swift
private var projectIconSection: some View {
    HStack(alignment: .top, spacing: 14) {
        VStack(spacing: 8) {
            ProjectIconView(icon: draftIcon, fallbackName: name, size: .dialog)
            HStack(spacing: 8) {
                ProjectIconView(icon: draftIcon, fallbackName: name, size: .sidebar)
                ProjectIconView(icon: draftIcon, fallbackName: name, size: .picker)
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            Seg(value: $iconMode, options: ProjectIcon.Mode.allCases.map { ($0, modeTitle($0)) })
            iconModeControls
            colorControls
        }
    }
}
```

Add:

```swift
private func modeTitle(_ mode: ProjectIcon.Mode) -> String {
    switch mode {
    case .letter: "Letter"
    case .symbol: "Symbol"
    case .emoji: "Emoji"
    case .image: "Image"
    }
}
```

- [ ] **Step 3: Add mode-specific controls**

Add:

```swift
@ViewBuilder
private var iconModeControls: some View {
    switch iconMode {
    case .letter:
        AlasField(text: $iconLabel, placeholder: ProjectIcon.fallbackLabel(projectName: name))
            .frame(width: 90)
    case .symbol:
        VStack(alignment: .leading, spacing: 6) {
            AlasField(text: $iconSymbolName, placeholder: "folder")
            symbolQuickChoices
        }
    case .emoji:
        AlasField(text: $iconEmoji, placeholder: "🚀")
            .frame(width: 90)
    case .image:
        imageControls
    }
}
```

Add curated symbol choices:

```swift
private var symbolQuickChoices: some View {
    HStack(spacing: 6) {
        ForEach(["folder", "terminal", "sparkle", "github", "gitlab", "commit"], id: \.self) { symbol in
            Button {
                iconSymbolName = symbol
            } label: {
                Icon(name: symbol, size: 13, color: theme.color("fg"))
                    .frame(width: 24, height: 24)
                    .background(iconSymbolName == symbol ? theme.color("bg-4") : theme.color("bg-2"))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help(symbol)
        }
    }
}
```

- [ ] **Step 4: Add color controls**

Replace `availablePalette` color references with `iconColor`. Add:

```swift
private var colorControls: some View {
    HStack(spacing: 8) {
        ForEach(availablePalette, id: \.self) { hex in
            Button { iconColor = hex } label: {
                Circle()
                    .fill(Color(hex: hex))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(.white, lineWidth: iconColor == hex ? 2 : 0))
            }
            .buttonStyle(.plain)
        }
        AlasField(text: $iconColor, placeholder: "#5fb7c4", monospaced: true)
            .frame(width: 96)
    }
}
```

Update `availablePalette`:

```swift
private var availablePalette: [String] {
    palette.contains(iconColor) ? palette : [iconColor] + palette
}
```

- [ ] **Step 5: Add image import and avatar controls**

Add:

```swift
private var imageControls: some View {
    VStack(alignment: .leading, spacing: 8) {
        AlasButton(title: "Choose Image…", icon: "image", action: chooseProjectIconImage)
        if let avatarPreset {
            HStack(spacing: 8) {
                Text(avatarPreset.label)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-muted"))
                AlasButton(
                    title: avatarPresetLoading ? "Loading…" : "Use",
                    action: useAvatarPreset
                )
                .disabled(avatarPresetData == nil || avatarPresetLoading)
            }
        } else if avatarPresetError {
            Text("Avatar preset unavailable")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
        }
    }
}
```

Add image chooser:

```swift
private func chooseProjectIconImage() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
    if panel.runModal() == .OK, let url = panel.url {
        do {
            let data = try Data(contentsOf: url)
            let projectId = existingProjectIdForIconStorage()
            let staged = try ProjectIconImageStaging.stage(data: data, projectId: projectId)
            iconImageAssetName = staged.assetName
            iconMode = .image
            errorMessage = nil
        } catch let stagingError as ProjectIconImageStaging.StagingError {
            errorMessage = stagingError.userMessage
        } catch {
            errorMessage = "Couldn't load that image. Please try another file."
        }
    }
}
```

Use a stable storage id:

```swift
private func existingProjectIdForIconStorage() -> String {
    if case .edit(let project) = mode { return project.id }
    return pendingIconStorageId
}
```

- [ ] **Step 6: Populate and save icon values**

In `populateInitialValues`, set:

```swift
iconMode = project.icon.mode
iconColor = project.icon.color
iconLabel = project.icon.label ?? ""
iconSymbolName = project.icon.symbolName ?? "folder"
iconEmoji = project.icon.emoji ?? "🚀"
iconImageAssetName = project.icon.imageAssetName
```

In add confirm:

```swift
try await state.addProject(path: url, displayName: name, icon: draftIcon)
```

In edit confirm:

```swift
state.updateProject(
    id: project.id,
    name: name,
    icon: draftIcon,
    startupScripts: ProjectStartupScripts(
        sessionOpenMode: sessionOpenMode,
        sessionOpenScript: sessionOpenScript,
        worktreeCreateMode: worktreeCreateMode,
        worktreeCreateScript: worktreeCreateScript,
        worktreeAgentMode: project.startupScripts.worktreeAgentMode,
        worktreeAgentId: project.startupScripts.worktreeAgentId,
        worktreeAgentUseBypassPermissions: project.startupScripts.worktreeAgentUseBypassPermissions
    )
)
```

- [ ] **Step 7: Fetch avatar preset without blocking dialog**

In `.onAppear`, call:

```swift
populateInitialValues()
Task { await loadAvatarPresetIfAvailable() }
```

Add:

```swift
private func loadAvatarPresetIfAvailable() async {
    let repoURL: URL
    switch mode {
    case .add:
        guard !path.isEmpty else { return }
        repoURL = URL(fileURLWithPath: path)
    case .edit(let project):
        repoURL = URL(fileURLWithPath: project.path)
    }

    avatarPresetLoading = true
    defer { avatarPresetLoading = false }

    do {
        let remotes = try await GitService().remotes(worktreePath: repoURL)
        guard let preset = ProjectAvatarPresetProvider.candidate(from: remotes) else { return }
        avatarPreset = preset
        avatarPresetData = try await ProjectAvatarPresetProvider.fetch(preset)
    } catch {
        avatarPresetError = true
    }
}
```

Add:

```swift
private func useAvatarPreset() {
    guard let data = avatarPresetData else { return }
    do {
        let staged = try ProjectIconImageStaging.stage(data: data, projectId: existingProjectIdForIconStorage())
        iconImageAssetName = staged.assetName
        iconMode = .image
        errorMessage = nil
    } catch let stagingError as ProjectIconImageStaging.StagingError {
        errorMessage = stagingError.userMessage
    } catch {
        errorMessage = "Couldn't save that avatar. Please try another image."
    }
}
```

- [ ] **Step 8: Run build and focused tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectIconTests -only-testing:AlasTests/ProjectConfigTests -only-testing:AlasTests/ProjectsManagerTests -quiet test
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: PASS.

- [ ] **Step 9: Commit**

Run:

```bash
rtk git add Alas/Sources/Dialogs/NewProjectDialog.swift
rtk git commit -m "feat: add project icon editor"
```

---

### Task 7: Compatibility Sweep and Final Verification

**Files:**
- Modify only files required by compile errors from API signature changes.
- Regenerate: `Alas.xcodeproj/project.pbxproj` if XcodeGen changes file references.

- [ ] **Step 1: Regenerate project**

Run:

```bash
rtk xcodegen
```

Expected: completes successfully. Sources are folder-based; keep `project.yml` unchanged unless XcodeGen reports a configuration error.

- [ ] **Step 2: Run focused icon suite**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -only-testing:AlasTests/ProjectIconTests -only-testing:AlasTests/ProjectIconImageStagingTests -only-testing:AlasTests/ProjectAvatarPresetProviderTests -only-testing:AlasTests/ProjectConfigTests -only-testing:AlasTests/ProjectsManagerTests -only-testing:AlasTests/RepoGroupViewLayoutTests -only-testing:AlasTests/ProjectPickerTests -quiet test
```

Expected: PASS.

- [ ] **Step 3: Run quiet build**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```

Expected: PASS.

- [ ] **Step 4: Run full tests**

Run:

```bash
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

Expected: PASS.

- [ ] **Step 5: Manual verification checklist**

Launch Alas locally and verify:

- Add project defaults to Letter mode with current first-letter behavior.
- Edit project Letter label to two characters and confirm sidebar/Cmd-K update.
- Pick a Symbol alias such as `github` and confirm sidebar/Cmd-K update.
- Pick an Emoji value and confirm sidebar/Cmd-K update.
- Import a PNG image, relaunch, and confirm it persists.
- Edit a GitHub/GitLab-backed project and confirm avatar preset appears without blocking the dialog.
- Disable network and confirm the dialog still opens and saves.

- [ ] **Step 6: Commit final compatibility fixes**

Run this when Task 7 changed files or regenerated project files:

```bash
rtk git add Alas.xcodeproj/project.pbxproj Alas/Sources AlasTests
rtk git commit -m "fix: finalize project icon integration"
```

When `rtk git status --short` prints no files, record "no final compatibility commit needed" in the task notes.

## Plan Self-Review

- Spec coverage: Tasks cover structured icon model, tolerant decode, image storage, avatar preset discovery/fetch, shared renderer, Add/Edit Project UI, target surfaces, error handling, and verification.
- Placeholder scan: no TBD/TODO/later placeholders remain. Conditional verification steps have explicit commands and expected outcomes.
- Type consistency: `ProjectIcon`, `ProjectIconView`, `ProjectIconImageStaging`, and `ProjectAvatarPresetProvider` names are consistent across tasks. The only intentional transition is `ProjectConfig.color` staying mirrored from `ProjectIcon.color`.
