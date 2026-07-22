import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStatePersistenceTests {
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
        var writtenProjectsFile: ProjectsFile?

        init(initialProjectsFile: ProjectsFile) {
            self.initialProjectsFile = initialProjectsFile
        }

        func write<T: Encodable>(_ value: T, to _: URL) throws {
            if let projectsFile = value as? ProjectsFile {
                writtenProjectsFile = projectsFile
            }
        }

        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            type == ProjectsFile.self ? initialProjectsFile as? T : nil
        }
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
