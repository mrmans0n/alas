# Repo-local `.alas/` configuration — Implementation Plan

> **REQUIRED SUB-SKILL:** Use the executing-plans skill to implement this plan task-by-task.

**Goal:** Load team-shared Alas config (icon, MCP servers, default worktree agent) from a committed `.alas/` directory in the repo, layered under per-user project settings, with trust-once approval for repo MCP servers.

**Architecture:** New decode-only `RepoConfig` model + mtime-cached `RepoConfigStore` reading `.alas/config.json` from a worktree root (local projects only in v1). Pure resolver functions implement the three-layer merge (global → repo → app); wiring happens at three existing seams: `ProjectIconView` call sites, `MCPAttachmentPlanner` via `MCPProjectContext`, and `AppState.defaultAgentID(projectID:)`. Trust and disables are per-user and persist on `ProjectConfig`. Design doc: `docs/plans/2026-09-17-repo-local-config-design.md`.

**Tech Stack:** Swift 5.9 / SwiftUI, Swift Testing (`import Testing`), Codable JSON.

**IMPORTANT repo conventions:**
- Test command pattern (run only the affected suite):
  ```
  xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
    -only-testing AlasTests/<SuiteName> test
  ```
- The Xcode project uses individually-referenced files (no synchronized folders). **Every task that creates a new file must run `xcodegen`** afterwards and include the regenerated `Alas.xcodeproj/project.pbxproj` in the same commit.
- v1 is **read-only** for `.alas/config.json` — no UI writes to the repo file.
- v1 reads repo config for **local projects only** (`project.host == nil`).
- Staging pipeline (`ProjectIconImageStaging.stage`) supports PNG/JPEG/GIF/WebP magic bytes only, so **icon discovery covers png/jpg/jpeg/gif/webp — no SVG in v1**.

---

### Task 1: `RepoConfig` model with tolerant decoding

**Files:**
- Create: `Alas/Sources/Persistence/RepoConfig.swift`
- Test: `AlasTests/Persistence/RepoConfigTests.swift`

**Step 1: Write the failing tests**

Create `AlasTests/Persistence/RepoConfigTests.swift`:

```swift
import Foundation
import Testing
@testable import Alas

@Suite("Repo config decoding")
struct RepoConfigTests {
    private func decode(_ json: String) -> RepoConfig? {
        RepoConfig(jsonData: Data(json.utf8))
    }

    @Test func decodesFullConfig() throws {
        let config = try #require(decode("""
        {
          "version": 1,
          "icon": { "image": "logo.png" },
          "defaultAgent": "pi",
          "mcpServers": [
            { "name": "linear", "transport": { "kind": "http", "url": "https://mcp.linear.app/mcp", "headers": [] } },
            { "name": "db", "transport": { "kind": "stdio", "command": "npx", "args": ["-y", "db-mcp"], "environment": [] } }
          ]
        }
        """))
        #expect(config.icon?.image == "logo.png")
        #expect(config.defaultAgent == "pi")
        #expect(config.mcpServers.map(\.name) == ["linear", "db"])
        #expect(config.mcpServers[0].id == "repo:linear")
        if case .http(let url, _) = config.mcpServers[0].transport {
            #expect(url == "https://mcp.linear.app/mcp")
        } else {
            Issue.record("expected http transport")
        }
    }

    @Test func rejectsMissingAndWrongVersion() {
        #expect(decode(#"{"defaultAgent": "pi"}"#) == nil)
        #expect(decode(#"{"version": 2, "defaultAgent": "pi"}"#) == nil)
        #expect(decode("not json at all") == nil)
    }

    @Test func ignoresUnknownKeys() throws {
        let config = try #require(decode(#"{"version": 1, "futureThing": {"x": 1}, "defaultAgent": "pi"}"#))
        #expect(config.defaultAgent == "pi")
    }

    @Test func skipsMalformedServersAndBlankNames() throws {
        let config = try #require(decode("""
        {
          "version": 1,
          "mcpServers": [
            { "name": "good", "transport": { "kind": "stdio", "command": "npx", "args": [], "environment": [] } },
            { "name": "   ", "transport": { "kind": "stdio", "command": "npx", "args": [], "environment": [] } },
            { "name": "broken", "transport": { "kind": "carrier-pigeon" } },
            { "name": "good", "transport": { "kind": "stdio", "command": "other", "args": [], "environment": [] } }
          ]
        }
        """))
        // blank names, undecodable transports, and duplicate names are skipped (first wins)
        #expect(config.mcpServers.map(\.name) == ["good"])
    }

    @Test func blankDefaultAgentBecomesNil() throws {
        let config = try #require(decode(#"{"version": 1, "defaultAgent": "  "}"#))
        #expect(config.defaultAgent == nil)
    }

    @Test func emptyFileDecodesToEmptyConfig() throws {
        #expect(try #require(decode(#"{"version": 1}"#")).isEmpty)
    }
}
```

**Step 2: Run to verify it fails**

```
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/RepoConfigTests test
```
Expected: FAIL — `RepoConfig` does not exist (and the test file isn't in the project until `xcodegen` runs in step 4; the failure then is a compile error, which is fine for red).

**Step 3: Implement**

Create `Alas/Sources/Persistence/RepoConfig.swift`:

```swift
import Foundation

/// Repo-local, team-shared Alas configuration decoded (read-only) from
/// `.alas/config.json`. See docs/plans/2026-09-17-repo-local-config-design.md.
struct RepoConfig: Equatable {
    static let currentVersion = 1
    static let relativePath = ".alas/config.json"

    struct Icon: Equatable {
        /// Image path relative to `.alas/`.
        var image: String
    }

    var icon: Icon?
    var defaultAgent: String?
    /// Servers get deterministic `repo:<name>` ids so a repo edit keeps
    /// identity across loads — the trust-hash flow depends on it.
    var mcpServers: [ProjectMCPServer]

    var isEmpty: Bool { icon == nil && defaultAgent == nil && mcpServers.isEmpty }

    init(icon: Icon? = nil, defaultAgent: String? = nil, mcpServers: [ProjectMCPServer] = []) {
        self.icon = icon
        self.defaultAgent = defaultAgent
        self.mcpServers = mcpServers
    }

    private struct Wire: Decodable {
        var version: Int
        var icon: Icon?
        var defaultAgent: String?
        var mcpServers: [TolerantServer]?

        struct Icon: Decodable { var image: String? }

        struct Server: Decodable {
            var name: String
            var transport: ProjectMCPTransport
        }

        /// A malformed entry must not sink the whole file.
        struct TolerantServer: Decodable {
            let server: Server?
            init(from decoder: Decoder) throws {
                server = try? Server(from: decoder)
            }
        }
    }

    /// Tolerant decode: wrong shape or version → nil (file treated as absent);
    /// bad individual entries are skipped; unknown keys are ignored.
    init?(jsonData: Data) {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: jsonData),
              wire.version == Self.currentVersion
        else { return nil }

        if let image = wire.icon?.image?.trimmingCharacters(in: .whitespacesAndNewlines), !image.isEmpty {
            icon = Icon(image: image)
        }
        let agent = wire.defaultAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        defaultAgent = agent.flatMap { $0.isEmpty ? nil : $0 }

        var seen = Set<String>()
        mcpServers = (wire.mcpServers ?? []).compactMap { entry in
            guard let server = entry.server else { return nil }
            let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return ProjectMCPServer(id: "repo:\(name)", name: name, transport: server.transport)
        }
    }
}
```

**Step 4: Register files and run tests**

```
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/RepoConfigTests test
```
Expected: PASS.

**Step 5: Commit**

```bash
git add Alas/Sources/Persistence/RepoConfig.swift AlasTests/Persistence/RepoConfigTests.swift Alas.xcodeproj/project.pbxproj
git commit -m "feat(config): add RepoConfig model with tolerant decoding"
```

> **Superseded by review (commit f8e7a596):** the whole-file `Wire` snippet
> above was replaced by a strict `VersionProbe` version gate plus a
> `RawContainer` that decodes `icon` / `defaultAgent` / `mcpServers`
> independently, so one mis-typed key only drops that key instead of the whole
> file. `icon.image` is also rejected at decode time when absolute or when it
> contains a `..` component. Read
> `Alas/Sources/Persistence/RepoConfig.swift` as the source of truth.

---

### Task 2: `RepoConfigStore` — mtime-cached loader + icon discovery

**Files:**
- Create: `Alas/Sources/Persistence/RepoConfigStore.swift`
- Test: `AlasTests/Persistence/RepoConfigStoreTests.swift`

The design requires malformed files to be distinguishable from absent ones and
logged to diagnostics, so the store must not collapse both into `nil`.

**Step 1: Write the failing tests**

Include a case asserting the load result distinguishes missing from malformed
(e.g. a `RepoConfigLoadResult` with `.missing` / `.loaded(RepoConfig)` /
`.malformed`), plus a test that an unreadable-but-present file logs through the
store's logger (assert the *result*, not the log text).

```swift
import Foundation
import Testing
@testable import Alas

@Suite("Repo config store")
struct RepoConfigStoreTests {
    private func makeWorktree() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-repo-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".alas", isDirectory: true),
            withIntermediateDirectories: true
        )
        return url
    }

    private func writeConfig(_ json: String, to root: URL) throws {
        try Data(json.utf8).write(
            to: root.appendingPathComponent(RepoConfig.relativePath), options: .atomic
        )
    }

    @Test func loadsConfigWhenPresent() throws {
        let root = try makeWorktree()
        try writeConfig(#"{"version": 1, "defaultAgent": "pi"}"#, to: root)
        #expect(RepoConfigStore().config(worktreeRoot: root)?.defaultAgent == "pi")
    }

    @Test func missingAndMalformedFilesReturnNil() throws {
        let root = try makeWorktree()
        let store = RepoConfigStore()
        #expect(store.config(worktreeRoot: root) == nil)
        try writeConfig("garbage", to: root)
        #expect(store.config(worktreeRoot: root) == nil)
    }

    @Test func reloadsWhenFileAppearsOrChanges() throws {
        let root = try makeWorktree()
        let store = RepoConfigStore()
        #expect(store.config(worktreeRoot: root) == nil)
        try writeConfig(#"{"version": 1, "defaultAgent": "a"}"#, to: root)
        #expect(store.config(worktreeRoot: root)?.defaultAgent == "a")
        // mtime-keyed cache: a rewrite with a later mtime must be picked up
        Thread.sleep(forTimeInterval: 0.02)
        try writeConfig(#"{"version": 1, "defaultAgent": "b"}"#, to: root)
        #expect(store.config(worktreeRoot: root)?.defaultAgent == "b")
    }

    @Test func discoversIconByExtensionOrder() throws {
        let root = try makeWorktree()
        let store = RepoConfigStore()
        #expect(store.discoveredIconURL(worktreeRoot: root) == nil)
        let png = root.appendingPathComponent(".alas/icon.png")
        let jpg = root.appendingPathComponent(".alas/icon.jpg")
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]).write(to: png)
        try Data([0xFF, 0xD8, 0xFF]).write(to: jpg)
        #expect(store.discoveredIconURL(worktreeRoot: root)?.lastPathComponent == "icon.png")
    }
}
```

Note: if the mtime cache flakily misses the "b" rewrite on fast filesystems, compare on the pair `(mtime, fileSize)` instead of mtime alone — encode that in the implementation to be safe (the two writes above differ in size).

**Step 2: Run to verify it fails** — same xcodebuild command with `-only-testing AlasTests/RepoConfigStoreTests`. Expected: compile error (type missing).

**Step 3: Implement** `Alas/Sources/Persistence/RepoConfigStore.swift`.

- File does not exist -> `.missing` (not logged).
- File exists but cannot be read (permissions, I/O) -> `.malformed`, logged.
- File readable but undecodable -> `.malformed`, logged.
- File readable and valid -> `.loaded` (never logged).

Log malformed files the way the rest of the app does
(`Logger(subsystem: "io.nlopez.alas", category: "repo-config")`), once per
distinct load and never on a cache hit, with the repo path interpolated as
`privacy: .public` — the diagnostic is only useful if it names the repo whose
config is broken. Classifying an unreadable file as "no config" was rejected in
review: a permissions problem must not look like an absent file.

```swift
import Foundation
import os

/// Reads `.alas/config.json` per worktree with an mtime-keyed cache. Every
/// lookup stats the file (cheap) and reparses on change, so `git pull` and
/// branch switches are picked up without file watchers. Local repos only —
/// callers pass remote projects as "no repo config".
final class RepoConfigStore {
    private struct Entry {
        let modificationDate: Date?
        let fileSize: Int?
        let config: RepoConfig?
    }

    private var cache: [String: Entry] = [:]

    func config(worktreeRoot: URL) -> RepoConfig? {
        let file = worktreeRoot.appendingPathComponent(RepoConfig.relativePath)
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        if let entry = cache[file.path],
           entry.modificationDate == values?.contentModificationDate,
           entry.fileSize == values?.fileSize {
            return entry.config
        }
        let config = (try? Data(contentsOf: file)).flatMap(RepoConfig.init(jsonData:))
        cache[file.path] = Entry(
            modificationDate: values?.contentModificationDate,
            fileSize: values?.fileSize,
            config: config
        )
        return config
    }

    /// PNG/JPEG/GIF/WebP — the staging pipeline's supported formats. No SVG.
    static let discoveredIconExtensions = ["png", "jpg", "jpeg", "gif", "webp"]

    func discoveredIconURL(worktreeRoot: URL) -> URL? {
        let fm = FileManager.default
        for ext in Self.discoveredIconExtensions {
            let url = worktreeRoot.appendingPathComponent(".alas/icon.\(ext)")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
```

**Step 4: `xcodegen`, run `AlasTests/RepoConfigStoreTests`.** Expected: PASS.

> **Superseded by implementation (commit 3ad0aeac + review fixes):** the snippet
> above shows the pre-review single-value shape. The shipped store exposes
> `RepoConfigLoadResult` (`missing` / `loaded` / `malformed`) through
> `load(worktreeRoot:)`, plus the `config(worktreeRoot:)` convenience; reads
> present-but-unreadable files as `.malformed` and logs them; and pins cache
> invalidation on both modification date and file size. Read
> `Alas/Sources/Persistence/RepoConfigStore.swift` as the source of truth.

**Step 5: Commit** — `feat(config): add mtime-cached RepoConfigStore with icon discovery`.

---

### Task 3: `RepoIconResolver` — effective-icon resolution via staging

Repo image paths cannot ride `ProjectIcon.imagePath` directly: `ProjectIconImageStaging.url(for:)` resolves it relative to `Paths.projectIconsRoot`. Resolution therefore *stages* the repo icon's bytes through the existing content-addressed pipeline (`stage(data:projectId:)` — idempotent by content hash), and returns an ordinary `.image` icon pointing at the staged copy.

**Files:**
- Create: `Alas/Sources/Persistence/RepoIconResolver.swift`
- Test: `AlasTests/Persistence/RepoIconResolverTests.swift`

**Step 1: Write the failing tests** (use a temp staging root — `stage(data:projectId:root:)` takes a root):

```swift
import Foundation
import Testing
@testable import Alas

@Suite("Repo icon resolution")
struct RepoIconResolverTests {
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])

    private func makeCheckout() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-icon-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".alas", isDirectory: true), withIntermediateDirectories: true
        )
        return url
    }

    @Test func defaultAppIconYieldsStagedRepoIcon() throws {
        let checkout = try makeCheckout()
        let staging = checkout.appendingPathComponent("staging", isDirectory: true)
        try pngBytes.write(to: checkout.appendingPathComponent(".alas/icon.png"))
        let resolved = RepoIconResolver.effectiveIcon(
            appIcon: .default(color: "#112233"),
            projectID: "p1",
            repoConfig: nil,
            primaryCheckout: checkout,
            store: RepoConfigStore(),
            stagingRoot: staging
        )
        #expect(resolved.mode == .image)
        #expect(resolved.imagePath?.hasPrefix("p1/") == true)
        #expect(resolved.color == "#112233")   // user's color carries over
    }

    @Test func explicitAppIconAlwaysWins() throws {
        let checkout = try makeCheckout()
        try pngBytes.write(to: checkout.appendingPathComponent(".alas/icon.png"))
        let explicit = ProjectIcon(mode: .emoji, color: "#112233", emoji: "🚀")
        let resolved = RepoIconResolver.effectiveIcon(
            appIcon: explicit, projectID: "p1", repoConfig: nil,
            primaryCheckout: checkout, store: RepoConfigStore(),
            stagingRoot: checkout.appendingPathComponent("staging")
        )
        #expect(resolved == explicit)
    }

    @Test func configKeyBeatsDiscoveredFile() throws {
        let checkout = try makeCheckout()
        try pngBytes.write(to: checkout.appendingPathComponent(".alas/icon.png"))
        try pngBytes.write(to: checkout.appendingPathComponent(".alas/logo.png"))
        // distinguish via config key pointing at logo.png; both stage, so
        // assert resolution reads the *config-keyed* file by making discovery
        // absent and only the config path present:
        // (flip: delete icon.png, keep logo.png)
        try FileManager.default.removeItem(at: checkout.appendingPathComponent(".alas/icon.png"))
        let config = RepoConfig(icon: .init(image: "logo.png"))
        let resolved = RepoIconResolver.effectiveIcon(
            appIcon: .default(), projectID: "p1", repoConfig: config,
            primaryCheckout: checkout, store: RepoConfigStore(),
            stagingRoot: checkout.appendingPathComponent("staging")
        )
        #expect(resolved.mode == .image)
    }

    @Test func missingFilesFallBackToAppIcon() throws {
        let checkout = try makeCheckout()
        let app = ProjectIcon.default()
        let resolved = RepoIconResolver.effectiveIcon(
            appIcon: app, projectID: "p1", repoConfig: RepoConfig(icon: .init(image: "nope.png")),
            primaryCheckout: checkout, store: RepoConfigStore(),
            stagingRoot: checkout.appendingPathComponent("staging")
        )
        #expect(resolved == app)
    }

    @Test func explicitnessHeuristic() {
        #expect(RepoIconResolver.iconIsExplicit(.default()) == false)
        #expect(RepoIconResolver.iconIsExplicit(.default(color: "#ff0000")) == false) // color alone is cosmetic
        #expect(RepoIconResolver.iconIsExplicit(.init(mode: .letter, color: "#5fb7c4", label: "AB")) == true)
        #expect(RepoIconResolver.iconIsExplicit(.init(mode: .symbol, color: "#5fb7c4", symbolName: "star")) == true)
    }
}
```

**Step 2: Run `AlasTests/RepoIconResolverTests`** — expected FAIL.

**Step 3: Implement** `Alas/Sources/Persistence/RepoIconResolver.swift`:

```swift
import Foundation

enum RepoIconResolver {
    /// An app-level icon counts as explicit when it is anything other than the
    /// untouched creation default (letter mode, no label/glyph/image chosen).
    /// A bare color pick is cosmetic and does NOT veto the repo icon.
    static func iconIsExplicit(_ icon: ProjectIcon) -> Bool {
        icon.mode != .letter
            || icon.label != nil
            || icon.symbolName != nil
            || icon.emoji != nil
            || icon.imagePath != nil
    }

    /// Icon to display for a project: explicit app icon → repo `icon` key →
    /// discovered `.alas/icon.<ext>` → app icon unchanged. Repo images are
    /// staged content-addressed so rendering reuses the existing pipeline;
    /// the user's color/background preferences carry over cosmetically.
    static func effectiveIcon(
        appIcon: ProjectIcon,
        projectID: String,
        repoConfig: RepoConfig?,
        primaryCheckout: URL,
        store: RepoConfigStore,
        stagingRoot: URL = Paths.projectIconsRoot
    ) -> ProjectIcon {
        guard !iconIsExplicit(appIcon) else { return appIcon }

        var candidates: [URL] = []
        if let image = repoConfig?.icon?.image {
            candidates.append(
                primaryCheckout.appendingPathComponent(".alas", isDirectory: true)
                    .appendingPathComponent(image)
            )
        }
        if let discovered = store.discoveredIconURL(worktreeRoot: primaryCheckout) {
            candidates.append(discovered)
        }

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let staged = try? ProjectIconImageStaging.stage(
                      data: data, projectId: projectID, root: stagingRoot
                  )
            else { continue }
            return ProjectIcon(
                mode: .image,
                color: appIcon.color,
                imagePath: staged.imagePath,
                transparentBackground: appIcon.transparentBackground
            )
        }
        return appIcon
    }
}
```

**Step 4: `xcodegen`, run suite.** Expected: PASS.

**Step 5: Commit** — `feat(config): resolve repo-provided project icons with app override`.

---

### Task 4: Wire the effective icon into project display

**Files:**
- Create: `Alas/Sources/App/AppState+RepoConfig.swift`
- Modify: `Alas/Sources/Sidebar/RepoGroupView.swift:69`, `Alas/Sources/Sidebar/WorkspaceSidebarTree.swift:270,481`, `Alas/Sources/App/RootView.swift:504`, `Alas/Sources/Dialogs/ProjectPicker.swift:23,87`, `Alas/Sources/Dialogs/Workspace/WorkspaceDialogs.swift:182`, `Alas/Sources/Dialogs/RepoSelector/RepoSelectorRowView.swift:82`

**Step 1: Implement** `AppState+RepoConfig.swift`:

```swift
import Foundation

extension AppState {
    /// Repo-local `.alas/config.json`, local projects only.
    func repoConfig(worktreeRoot: URL) -> RepoConfig? {
        repoConfigStore.config(worktreeRoot: worktreeRoot)
    }

    /// Project icon with the repo layer applied. Remote projects and explicit
    /// app icons are untouched. Resolved from the repo's primary checkout.
    func effectiveIcon(for project: ProjectConfig) -> ProjectIcon {
        guard project.host == nil else { return project.icon }
        let checkout = URL(fileURLWithPath: project.path, isDirectory: true)
        return RepoIconResolver.effectiveIcon(
            appIcon: project.icon,
            projectID: project.id,
            repoConfig: repoConfigStore.config(worktreeRoot: checkout),
            primaryCheckout: checkout,
            store: repoConfigStore
        )
    }
}
```

Add `let repoConfigStore = RepoConfigStore()` to `AppState` near its other stored services (search `final class AppState` for an appropriate grouping).

**Caching is required here, not optional.** `ProjectIconImageStaging.stage` reads
and SHA-256s the image on every call, and `effectiveIcon(for:)` runs on sidebar
render paths, so resolving uncached would re-read the icon bytes per render
pass. Keep a small per-project cache in this extension keyed by
`project.id` plus the resolved repo icon's `(path, modificationDate, fileSize)`:
on a key match return the previously resolved `ProjectIcon` without touching
disk, otherwise resolve and store. Entries are tiny and bounded by the number
of projects on screen; no eviction API is needed in v1, but drop the entry when
the project has no repo icon (so a later-added `icon.png` is picked up). This is
the seam the design promised ("icons resolve to absolute path + mtime").

**Step 2: Update the call sites.** At each of the 8 locations, `ProjectIconView(icon: project.icon, ...)` becomes `ProjectIconView(icon: appState.effectiveIcon(for: project), ...)`. Every listed view already has `AppState` in scope (`@EnvironmentObject` or parameter) — verify per file; if one lacks it, add `@EnvironmentObject var appState: AppState`. Do NOT touch `NewProjectDialog.swift:484-487` (creation draft) or worktree-level icons.

**Step 3: Build check**

```
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
```
Expected: BUILD SUCCEEDED.

**Step 4: Commit** — `feat(sidebar): display repo-provided icon for projects without an explicit one`.

---

### Task 5: Trust fields on `ProjectConfig` + trust hashing

**Files:**
- Create: `Alas/Sources/Persistence/RepoMCPTrust.swift`
- Modify: `Alas/Sources/Persistence/ProjectConfig.swift` (fields, `CodingKeys`, memberwise init, tolerant decode, sparse encode)
- Test: `AlasTests/Persistence/RepoMCPTrustTests.swift`

**Step 1: Failing tests**

```swift
@Suite("Repo MCP trust")
struct RepoMCPTrustTests {
    @Test func hashIsStableForSameConfigAndChangesWithConfig() {
        let a = ProjectMCPServer(id: "repo:x", name: "x",
            transport: .stdio(command: "npx", args: ["s"], environment: []))
        let same = ProjectMCPServer(id: "other-id", name: "x",
            transport: .stdio(command: "npx", args: ["s"], environment: []))
        let edited = ProjectMCPServer(id: "repo:x", name: "x",
            transport: .stdio(command: "npx", args: ["t"], environment: []))
        #expect(RepoMCPTrust.hash(for: a) == RepoMCPTrust.hash(for: same))
        #expect(RepoMCPTrust.hash(for: a) != RepoMCPTrust.hash(for: edited))
    }

    @Test func projectConfigRoundTripsTrustFieldsTolerantly() throws {
        var project = ProjectConfig(id: "p", name: "n", path: "/tmp/n",
                                    color: "#5fb7c4", addedAt: Date())
        project.repoMCPTrust = ["abc": .approved, "def": .declined]
        project.disabledRepoMCPServers = ["linear"]
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)
        #expect(decoded.repoMCPTrust == ["abc": .approved, "def": .declined])
        #expect(decoded.disabledRepoMCPServers == ["linear"])

        // files written before this feature decode with empty trust state
        let legacy = try JSONDecoder().decode(ProjectConfig.self, from: data)
        #expect(legacy.issueAttachments == decoded.issueAttachments)
    }
}
```

**Step 2: Run `AlasTests/RepoMCPTrustTests`** — expected FAIL.

**Step 3: Implement**

`Alas/Sources/Persistence/RepoMCPTrust.swift`:

```swift
import Foundation

/// Per-user decision about an MCP server a repo wants to attach. Trust is
/// keyed by a hash of the server's canonical config, so editing the server in
/// the repo re-prompts, and the same config stays approved across branches.
enum RepoMCPTrustState: String, Codable, Equatable {
    case approved
    case declined
}

enum RepoMCPTrust {
    static func hash(for server: ProjectMCPServer) -> String {
        // Reuse the attachment fingerprint's canonical encoding:
        // same config → same hash, independent of the derived id.
        MCPAttachmentPlanner.configurationFingerprint(for: [server])
    }
}
```

In `ProjectConfig`: add stored properties

```swift
/// Per-user trust decisions for repo-defined MCP servers, keyed by
/// `RepoMCPTrust.hash(for:)`.
var repoMCPTrust: [String: RepoMCPTrustState] = [:]
/// Names of repo-defined MCP servers the user disabled without overriding.
var disabledRepoMCPServers: [String] = []
```

Add both names to `CodingKeys`, to the memberwise init (defaulted), tolerant-decode them with `?? [:]` / `?? []`, and encode sparsely (skip when empty), mirroring how `issueAttachments` is handled in that file.

**Step 4: `xcodegen`, run `AlasTests/RepoMCPTrustTests` and `AlasTests/ProjectMCPServerTests`** (regression). Expected: PASS.

**Step 5: Commit** — `feat(config): persist per-user trust for repo MCP servers`.

---

### Task 6: `RepoMCPResolver` — merge-by-name with trust filtering

**Files:**
- Create: `Alas/Sources/Persistence/RepoMCPResolver.swift`
- Test: `AlasTests/Persistence/RepoMCPResolverTests.swift`

**Step 1: Failing tests** — cover the rule table:

```swift
@Suite("Repo MCP merge")
struct RepoMCPResolverTests {
    private func repo(_ name: String, command: String = "npx") -> ProjectMCPServer {
        ProjectMCPServer(id: "repo:\(name)", name: name,
                         transport: .stdio(command: command, args: [], environment: []))
    }
    private func app(_ name: String) -> ProjectMCPServer {
        ProjectMCPServer(id: UUID().uuidString, name: name,
                         transport: .stdio(command: "mine", args: [], environment: []))
    }

    @Test func appServerShadowsRepoServerByName() {
        let result = RepoMCPResolver.merge(
            appServers: [app("linear")], repoServers: [repo("linear")],
            disabledNames: [], trust: [:]
        )
        #expect(result.active.map(\.name) == ["linear"])
        #expect(result.active.first?.id != "repo:linear")
        #expect(result.skipped.map(\.reason) == [.shadowedByApp])
        #expect(result.pendingApproval.isEmpty)
    }

    @Test func approvedRepoServerAttaches() {
        let server = repo("linear")
        let result = RepoMCPResolver.merge(
            appServers: [], repoServers: [server],
            disabledNames: [], trust: [RepoMCPTrust.hash(for: server): .approved]
        )
        #expect(result.active == [server])
    }

    @Test func unknownTrustIsPendingAndInactive() {
        let server = repo("linear")
        let result = RepoMCPResolver.merge(
            appServers: [], repoServers: [server], disabledNames: [], trust: [:]
        )
        #expect(result.active.isEmpty)
        #expect(result.pendingApproval == [server])
        #expect(result.skipped.map(\.reason) == [.notApproved])
    }

    @Test func declinedAndDisabledStayInactive() {
        let declined = repo("a")
        let disabled = repo("b")
        let result = RepoMCPResolver.merge(
            appServers: [], repoServers: [declined, disabled],
            disabledNames: ["b"], trust: [RepoMCPTrust.hash(for: declined): .declined]
        )
        #expect(result.active.isEmpty)
        #expect(result.pendingApproval.isEmpty)
        #expect(Set(result.skipped.map(\.reason)) == [.declined, .disabled])
    }

    @Test func trimmedNameMatching() {
        let result = RepoMCPResolver.merge(
            appServers: [app("linear")], repoServers: [repo(" linear ")],
            disabledNames: [], trust: [:]
        )
        #expect(result.skipped.map(\.reason) == [.shadowedByApp])
    }
}
```

Note: repo server decoding already trims names (Task 1), so the last test exercises the resolver's own trimming against untrusted/late-binding inputs.

**Step 2: Run `AlasTests/RepoMCPResolverTests`** — expected FAIL.

**Step 3: Implement** `Alas/Sources/Persistence/RepoMCPResolver.swift`:

```swift
import Foundation

enum RepoMCPResolver {
    enum SkipReason: Equatable {
        case shadowedByApp
        case disabled
        case declined
        case notApproved
    }

    struct Skipped: Equatable {
        var server: ProjectMCPServer
        var reason: SkipReason
    }

    struct Result: Equatable {
        /// App servers plus repo servers cleared to attach, in stable order.
        var active: [ProjectMCPServer]
        var skipped: [Skipped]
        /// Repo servers with no trust decision yet — drives the banner.
        var pendingApproval: [ProjectMCPServer]
    }

    /// Merge by name: app-level servers always win; repo servers attach only
    /// when approved, and stay quiet when declined or disabled.
    static func merge(
        appServers: [ProjectMCPServer],
        repoServers: [ProjectMCPServer],
        disabledNames: Set<String>,
        trust: [String: RepoMCPTrustState]
    ) -> Result {
        let appNames = Set(appServers.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
        var result = Result(active: appServers, skipped: [], pendingApproval: [])

        for server in repoServers {
            let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if appNames.contains(name) {
                result.skipped.append(.init(server: server, reason: .shadowedByApp))
            } else if disabledNames.contains(name) {
                result.skipped.append(.init(server: server, reason: .disabled))
            } else {
                switch trust[RepoMCPTrust.hash(for: server)] {
                case .approved:
                    result.active.append(server)
                case .declined:
                    result.skipped.append(.init(server: server, reason: .declined))
                case nil:
                    result.pendingApproval.append(server)
                    result.skipped.append(.init(server: server, reason: .notApproved))
                }
            }
        }
        return result
    }
}
```

**Step 4: `xcodegen`, run suite.** Expected: PASS.

**Step 5: Commit** — `feat(config): merge repo MCP servers by name with trust gating`.

---

### Task 7: Planner integration — repo servers in the attachment plan

**Files:**
- Modify: `Alas/Sources/ACP/Session/MCPAttachmentPlanner.swift` (`MCPAttachmentSkipReason`, `MCPProjectContext`, `plan` non-frozen path)
- Test: extend the existing planner suite — find it with `rg -l "MCPAttachmentPlanner.plan" AlasTests` (likely `AlasTests/ACP/…`)

**Step 1: Failing tests** (add to the planner suite):

```swift
@Test func approvedRepoServersJoinThePlanAndUnapprovedAreSkipped() {
    let repo = ProjectMCPServer(id: "repo:extra", name: "extra",
        transport: .stdio(command: "tool", args: [], environment: []))
    let context = MCPProjectContext(
        projectDirectory: "/p",
        configuredServers: [.stdio(name: "app", command: "mine")],
        repoServers: [repo],
        disabledRepoServerNames: [],
        repoTrust: [RepoMCPTrust.hash(for: repo): .approved]
    )
    let plan = MCPAttachmentPlanner.plan(input-from-context…)  // match existing suite's input plumbing
    #expect(plan.statuses.map(\.name).contains("extra"))
}
```

Plus: unknown-trust repo server → status disposition `.skipped(.repoNotApproved)`; disabled → `.skipped(.repoDisabled)`; frozen descriptor path unchanged (checkout snapshots never see repo servers — assert that).

Match the exact `plan(_:)` input construction the existing tests use; keep the assertions on `plan.statuses` / `plan.wireServers`.

**Step 2: Run the planner suite** — expected FAIL.

**Step 3: Implement**

- Add cases to `MCPAttachmentSkipReason`:
  ```swift
  /// Repo-defined server without an approval decision (or declined).
  case repoNotApproved
  /// Repo-defined server the user disabled for this project.
  case repoDisabled
  ```
- Extend `MCPProjectContext` with defaulted fields so existing call sites compile untouched:
  ```swift
  var repoServers: [ProjectMCPServer] = []
  var disabledRepoServerNames: Set<String> = []
  var repoTrust: [String: RepoMCPTrustState] = [:]
  ```
  (Update the memberwise init + `Equatable` — it is synthesized, fields suffice.)
- In `MCPAttachmentPlanner.plan`, only on the **non-frozen** path (`input.frozenServerDescriptors == nil`): call `RepoMCPResolver.merge` with the context's app servers, repo servers, disabled names, and trust; use `merged.active` as `configuredServers` when building descriptors, then append statuses for `merged.skipped` — mapping `.declined`/`.notApproved` → `.skipped(.repoNotApproved)` and `.disabled` → `.skipped(.repoDisabled)`. Do not include repo servers in the frozen path.
- Check `ACPMCPStatusControl`/`ACPMCPStatusPolicy` rendering of skip reasons and add display strings for the two new cases ("Not enabled (repo — pending approval)" / "Disabled (repo)").

**Step 4: Run the planner suite + `AlasTests/RepoMCPResolverTests`.** Expected: PASS.

**Step 5: Commit** — `feat(mcp): attach approved repo-defined servers to sessions`.

---

### Task 8: Wire repo servers into the session context provider

**Files:**
- Modify: `Alas/Sources/App/AppState.swift` (~line 10064, the `mcpProjectContextProvider` closure)

**Step 1:** In the provider closure, after resolving `project` (note the store's
tri-state result — a `.malformed` file contributes no repo servers, exactly like
`.missing`, but has already been logged):

```swift
let isLocal = project.host == nil
let repo = isLocal
    ? repoConfigStore.config(worktreeRoot: URL(fileURLWithPath: worktree.path, isDirectory: true))
    : nil
return MCPProjectContext(
    projectDirectory: project.path,
    configuredServers: project.mcpServers,
    repoServers: repo?.mcpServers ?? [],
    disabledRepoServerNames: Set(project.disabledRepoMCPServers),
    repoTrust: project.repoMCPTrust
)
```

`worktree.path` is the closure's existing capture — match the surrounding code's actual property name (`worktreePath` is used nearby; use the one in scope).

**Step 2: Build check** (`-quiet build`), then run the planner suite once more.

**Step 3: Commit** — `feat(mcp): feed repo config into session attachment context`.

---

### Task 9: Trust approval banner + persistence mutations

**Files:**
- Modify: `Alas/Sources/App/ProjectsManager.swift` (mutation methods — follow the existing "load, mutate, persist, publish" pattern used by other project property updates)
- Create: `Alas/Sources/ACP/UI/RepoMCPTrustBannerPolicy.swift` (pure decision logic)
- Create: `Alas/Sources/ACP/UI/RepoMCPTrustBanner.swift` (SwiftUI banner; model on `ACPSetupNudgeBanner.swift`)
- Test: `AlasTests/ACP/RepoMCPTrustBannerPolicyTests.swift`

**Step 1: Failing policy tests**

```swift
@Suite("Repo MCP trust banner policy")
struct RepoMCPTrustBannerPolicyTests {
    // pending servers exist + project local + host nil → show banner with names
    // all decided → hidden; remote host → hidden; no repo config → hidden
}
```

**Step 2: Run** — expected FAIL.

**Step 3: Implement**

`RepoMCPTrustBannerPolicy`:

```swift
struct RepoMCPTrustBannerDecision: Equatable {
    let pendingServers: [ProjectMCPServer]
    var isVisible: Bool { !pendingServers.isEmpty }
}

enum RepoMCPTrustBannerPolicy {
    static func decision(project: ProjectConfig, repoConfig: RepoConfig?) -> RepoMCPTrustBannerDecision {
        guard project.host == nil, let repoConfig else {
            return .init(pendingServers: [])
        }
        let merged = RepoMCPResolver.merge(
            appServers: project.mcpServers,
            repoServers: repoConfig.mcpServers,
            disabledNames: Set(project.disabledRepoMCPServers),
            trust: project.repoMCPTrust
        )
        return .init(pendingServers: merged.pendingApproval)
    }
}
```

`ProjectsManager` additions:

```swift
func setRepoMCPTrust(projectID: String, hash: String, state: RepoMCPTrustState)
func setRepoMCPServerDisabled(projectID: String, name: String, disabled: Bool)
```

(Insert/remove from the arrays on a copy of the project, then persist through the same channel existing update methods use.)

`RepoMCPTrustBanner`: nudge-style banner — "This repo defines N MCP server(s)" + names, buttons **Approve All**, **Decline**, and **Review…** opening a read-only detail sheet (name, transport kind, command/URL, env/header *names* only). Approve All/decisions call the `ProjectsManager` mutations above. Mount it where `ACPSetupNudgeBanner` is mounted for a project/workspace context (read that banner's mounting point and mirror it).

**Step 4: `xcodegen`, run the policy suite**, then `-quiet build`.

**Step 5: Commit** — `feat(mcp): prompt for trust on repo-defined MCP servers`.

---

### Task 10: Default agent — three-layer resolution

**Files:**
- Modify: `Alas/Sources/Persistence/ProjectConfig.swift` (`ProjectStartupScripts.defaultAgentID`)
- Modify: `Alas/Sources/App/AppState.swift:3784` (`defaultAgentID(projectID:)`)
- Test: `AlasTests/Persistence/ProjectStartupScriptsTests.swift` (create; check first whether a suite already covers `defaultAgentID` via `rg -l "defaultAgentID" AlasTests`)

**Step 1: Failing tests**

```swift
@Test func useGlobalPrefersRepoDefaultThenGlobal() {
    var scripts = ProjectStartupScripts.defaults
    #expect(scripts.defaultAgentID(repoDefaultAgent: "pi", globalAgentID: "claude") == "pi")
    #expect(scripts.defaultAgentID(repoDefaultAgent: nil, globalAgentID: "claude") == "claude")
    scripts.worktreeAgentMode = .overrideGlobal
    scripts.worktreeAgentId = "mine"
    #expect(scripts.defaultAgentID(repoDefaultAgent: "pi", globalAgentID: "claude") == "mine")
    scripts.worktreeAgentMode = .disabled
    #expect(scripts.defaultAgentID(repoDefaultAgent: "pi", globalAgentID: "claude") == nil)
}
```

**Step 2: Run** — expected FAIL.

**Step 3: Implement** — replace `defaultAgentID(globalAgentID:)`:

```swift
func defaultAgentID(repoDefaultAgent: String?, globalAgentID: String?) -> String? {
    switch worktreeAgentMode {
    case .useGlobal: repoDefaultAgent ?? globalAgentID
    case .disabled: nil
    case .overrideGlobal, .appendToGlobal: worktreeAgentId
    }
}

// Back-compat shim for existing callers/tests.
func defaultAgentID(globalAgentID: String?) -> String? {
    defaultAgentID(repoDefaultAgent: nil, globalAgentID: globalAgentID)
}
```

Wire `AppState.defaultAgentID(projectID:)`: resolve repo default only for local projects, from the primary checkout, and only if the id matches a known enabled `AgentDefinition` (same list `ProjectAgentSettingsView` receives — source it the same way that view's caller does); unknown ids fall through to global. `worktreeAgentUseBypassPermissions` stays app-only: no changes there.

**Step 4: `xcodegen` (if new test file), run the suite + any existing default-agent suite found above.** Expected: PASS.

**Step 5: Commit** — `feat(agents): repo default agent under project and global overrides`.

---

### Task 11: Settings caption for the repo default agent

**Files:**
- Modify: `Alas/Sources/Dialogs/ProjectAgentSettingsView.swift`

**Step 1:** Where `scripts.agentSelection == .global` (around line 36), the view currently describes the global default. When an effective repo default exists for this project, extend that caption: "Repo default: pi (from `.alas/config.json`)" taking display precedence over the global text. The view needs the repo default passed in or resolvable — add an optional `repoDefaultAgentName: String?` parameter to the view and pass it from the caller (resolve via `AppState` + agent display-name lookup, mirroring lines 13–16).

**Step 2: Build check** (`-quiet build`).

**Step 3: Commit** — `feat(settings): caption repo-provided default agent in project settings`.

---

### Task 12: Docs

**Files:**
- Modify: `README.md` — short section on `.alas/` repo config: `config.json` shape, icon discovery, trust flow, examples. The JSON example must be **complete and copy-pasteable**, matching the app's exact persisted shape (discriminator `kind`, stdio `args`+`environment`, http/sse `headers`, and an `id` on every env/header entry) — a sketch that omits those keys silently drops servers. Note that icon discovery covers png/jpg/jpeg/gif/webp and that SVG is not supported in v1.
- Modify: `docs/plans/2026-09-17-repo-local-config-design.md` — one-line addendum noting SVG was dropped from discovery (staging pipeline supports PNG/JPEG/GIF/WebP only).

Docs-only change: no build, no tests. **Commit** — `docs: document repo-local .alas configuration`.
