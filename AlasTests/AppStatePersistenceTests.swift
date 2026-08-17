import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStatePersistenceTests {
    private static let githubSourceLocator = IssueRepositoryLocator(
        provider: .github,
        host: "github.com",
        repositorySlug: "acme/alas"
    )

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private struct FailingStore: PersistenceStoreProtocol {
        let error = NSError(
            domain: "AppStatePersistenceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "write rejected"]
        )

        func write<T: Encodable>(_: T, to _: URL) throws {
            throw error
        }

        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? {
            nil
        }
    }

    private final class RecordingStore: PersistenceStoreProtocol, @unchecked Sendable {
        let initialProjectsFile: ProjectsFile
        var writtenConfig: AppConfig?
        var writtenProjectsFile: ProjectsFile?
        var configWriteCount = 0

        init(initialProjectsFile: ProjectsFile) {
            self.initialProjectsFile = initialProjectsFile
        }

        func write<T: Encodable>(_ value: T, to _: URL) throws {
            if let config = value as? AppConfig {
                writtenConfig = config
                configWriteCount += 1
            }
            if let projectsFile = value as? ProjectsFile {
                writtenProjectsFile = projectsFile
            }
        }

        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            type == ProjectsFile.self ? initialProjectsFile as? T : nil
        }
    }

    @Test func issueAttachmentsAreScopedAndPersisted() {
        let project = ProjectConfig(
            id: "project", name: "App", path: "/tmp/app", color: "#5fb7c4", addedAt: .distantPast
        )
        let store = RecordingStore(initialProjectsFile: .init(projects: [project]))
        let state = AppState(store: store)
        let attachment = IssueAttachment(
            canonicalURL: URL(string: "https://github.com/acme/app/issues/42")!,
            providerLabel: "GitHub",
            displayReference: "#42",
            title: "Prevent parser crash"
        )

        state.projectsManager.setIssueAttachment(
            projectId: project.id,
            worktreeId: "worktree-a",
            attachment: attachment
        )
        state.saveProjects()

        #expect(state.projectsManager.issueAttachment(projectId: project.id, worktreeId: "worktree-a") == attachment)
        #expect(state.projectsManager.issueAttachment(projectId: project.id, worktreeId: "worktree-b") == nil)
        #expect(store.writtenProjectsFile?.projects[0].issueAttachments == ["worktree-a": attachment])

        state.projectsManager.removeIssueAttachment(projectId: project.id, worktreeId: "worktree-a")

        #expect(state.projectsManager.issueAttachment(projectId: project.id, worktreeId: "worktree-a") == nil)
    }

    @Test func worktreeRefreshRetainsLiveIssueAttachmentsAndPrunesMissingOnes() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-issue-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)

        let liveID = Worktree.makeId(path: repo)
        let attachment = IssueAttachment(
            canonicalURL: URL(string: "https://github.com/acme/app/issues/42")!,
            providerLabel: "GitHub",
            displayReference: "#42",
            title: "Prevent parser crash"
        )
        let project = ProjectConfig(
            id: "project", name: "App", path: repo.path, color: "#5fb7c4", addedAt: .distantPast,
            issueAttachments: [liveID: attachment, "missing-worktree": attachment]
        )
        let state = AppState(store: RecordingStore(initialProjectsFile: .init(projects: [project])))

        let changed = try await state.projectsManager.refreshWorktrees(projectId: project.id)

        #expect(changed)
        #expect(state.projectsManager.projects[0].issueAttachments == [liveID: attachment])
    }

    @Test func setDefaultWorktreeOrderingPersistsAndPreservesManualOverrides() {
        let inherited = ProjectConfig(
            id: "inherited", name: "Inherited", path: "/repo/inherited",
            color: "blue", addedAt: .now
        )
        let manualNew = Worktree.makeId(path: URL(fileURLWithPath: "/repo/manual/wts/new"))
        let manualOld = Worktree.makeId(path: URL(fileURLWithPath: "/repo/manual/wts/old"))
        let manual = ProjectConfig(
            id: "manual", name: "Manual", path: "/repo/manual",
            color: "red", addedAt: .now,
            worktreeOrder: [manualOld, manualNew],
            worktreeOrderIsManual: true
        )
        let store = RecordingStore(initialProjectsFile: .init(projects: [inherited, manual]))
        let state = AppState(store: store)
        let now = Date(timeIntervalSince1970: 2_000)

        func worktree(projectID: String, path: String, branch: String, activity: Date) -> Worktree {
            let url = URL(fileURLWithPath: path)
            return Worktree(
                id: Worktree.makeId(path: url), projectId: projectID,
                name: branch, branch: branch, path: url, status: .clean,
                lastActivity: activity, createdAt: activity
            )
        }

        let rows = [
            worktree(projectID: inherited.id, path: inherited.path, branch: "main", activity: now),
            worktree(projectID: inherited.id, path: "/repo/inherited/wts/zeta", branch: "zeta", activity: now),
            worktree(projectID: inherited.id, path: "/repo/inherited/wts/alpha", branch: "alpha", activity: now.addingTimeInterval(-60)),
            worktree(projectID: manual.id, path: "/repo/manual/wts/old", branch: "old", activity: now.addingTimeInterval(-60)),
            worktree(projectID: manual.id, path: manual.path, branch: "main", activity: now),
            worktree(projectID: manual.id, path: "/repo/manual/wts/new", branch: "new", activity: now),
        ]
        for row in rows {
            state.projectsManager.insertOptimisticWorktree(row)
            state.projectsManager.setOperationState(id: row.id, state: nil)
        }

        state.setDefaultWorktreeOrdering(.branchAsc)

        #expect(state.config.worktrees.defaultOrdering == .branchAsc)
        #expect(store.writtenConfig?.worktrees.defaultOrdering == .branchAsc)
        #expect(state.projectsManager.worktrees(projectId: inherited.id).map(\.branch)
            == ["main", "alpha", "zeta"])
        #expect(state.projectsManager.worktrees(projectId: manual.id).map(\.branch)
            == ["main", "old", "new"])
        #expect(state.projectsManager.projects[1].worktreeOrderIsManual)
    }

    @Test func setDefaultWorktreeOrderingDoesNotPersistTheActiveModeAgain() {
        let store = RecordingStore(initialProjectsFile: .init(projects: []))
        let state = AppState(store: store)

        state.setDefaultWorktreeOrdering(state.config.worktrees.defaultOrdering)

        #expect(store.configWriteCount == 0)
        #expect(store.writtenProjectsFile == nil)
    }

    @Test func saveConfigReportsWriteFailure() {
        var reports: [(title: String, message: String)] = []
        let state = AppState(store: FailingStore()) { title, message in
            reports.append((title, message))
        }

        let saved = state.saveConfig()

        #expect(saved == false)
        #expect(reports.map(\.title) == ["Settings Save Failed"])
        #expect(reports.first?.message == "write rejected")
    }

    @Test func saveProjectsReportsWriteFailure() {
        var reports: [(title: String, message: String)] = []
        let state = AppState(store: FailingStore()) { title, message in
            reports.append((title, message))
        }

        let saved = state.saveProjects()

        #expect(saved == false)
        #expect(reports.map(\.title) == ["Projects Save Failed"])
        #expect(reports.first?.message == "write rejected")
    }

    @Test func deletedWorktreeOverrideIsRemovedAndPersistedBeforeTopologyRefresh() throws {
        let persistedProject = ProjectConfig(
            id: "project",
            name: "Alas",
            path: "/tmp/alas",
            color: "teal",
            addedAt: .now
        )
        let store = RecordingStore(
            initialProjectsFile: ProjectsFile(projects: [persistedProject])
        )
        let state = AppState(store: store)
        state.projectsManager.setGGWorktreeMode(
            projectId: persistedProject.id,
            worktreeId: "deleted-worktree",
            mode: .on
        )

        state.removePersistedGGWorktreeMode(
            projectId: persistedProject.id,
            worktreeId: "deleted-worktree"
        )

        #expect(state.projectsManager.ggWorktreeMode(
            projectId: persistedProject.id,
            worktreeId: "deleted-worktree"
        ) == .inherit)
        #expect(store.writtenProjectsFile?.projects.first?.ggWorktreeModes.isEmpty == true)
    }

    @Test func shortcutOverridesPersistThroughSaveAndReload() throws {
        let state = AppState(store: MemoryStore())
        state.setShortcut(ShortcutBinding(key: "o", modifiers: [.command]), for: .searchFiles)
        state.setShortcut(nil, for: .switchRepository)
        // Reload by encoding/decoding via AppConfig (mirrors what disk does).
        let data = try JSONEncoder().encode(state.config)
        let reloaded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(reloaded.shortcutOverrides[ShortcutAction.searchFiles.rawValue] ==
                .some(ShortcutBinding(key: "o", modifiers: [.command])))
        #expect(reloaded.shortcutOverrides[ShortcutAction.switchRepository.rawValue] == .some(nil))
    }

    @Test func languageServerRegistryRefreshesOnlyWhenLanguageServersChange() {
        var tracker = AppState.LanguageServerConfigChangeTracker(
            initial: AppConfig.defaults.code.languageServers
        )

        var widthOnlyConfig = AppConfig.defaults
        widthOnlyConfig.sidebarWidth = 300
        #expect(tracker.consumeChange(in: widthOnlyConfig) == false)

        var languageServerConfig = widthOnlyConfig
        languageServerConfig.code.languageServers = [
            LanguageServerConfig(
                language: "swift",
                extensions: ["swift"],
                command: "/usr/bin/sourcekit-lsp",
                args: [],
                env: [:],
                rootMarkers: ["Package.swift"],
                enabled: true
            )
        ]
        #expect(tracker.consumeChange(in: languageServerConfig) == true)
        #expect(tracker.consumeChange(in: languageServerConfig) == false)
    }
}
