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

    @Test func archivingMissionWorktreeRecordsExplicitReadySignal() async throws {
        let project = Self.project
        let persistence = try Self.makeMissionPersistence()
        let state = AppState(
            store: RecordingStore(initialProjectsFile: .init(projects: [project])),
            missionPersistence: persistence
        )
        let worktree = Self.worktree
        state.projectsManager.insertOptimisticWorktree(worktree)
        await state.missions.load()

        state.archiveWorktree(worktree)
        let aggregate = try await Self.waitForMissionState(.readyToComplete, persistence: persistence)

        #expect(state.projectsManager.isWorktreeHidden(projectId: project.id, path: worktree.path))
        #expect(aggregate.events.last?.kind == .ready)
        #expect(aggregate.events.last?.message == "Worktree archived in Alas.")
    }

    @Test func removingMissionProjectRecordsAttentionWithoutDeletingMission() async throws {
        let project = Self.project
        let persistence = try Self.makeMissionPersistence()
        let state = AppState(
            store: RecordingStore(initialProjectsFile: .init(projects: [project])),
            missionPersistence: persistence
        )
        await state.missions.load()

        #expect(state.removeProject(id: project.id))
        let aggregate = try await Self.waitForMissionState(.needsAttention, persistence: persistence)

        #expect(aggregate.mission.attentionReason == "The Mission project is no longer available.")
        #expect(aggregate.issue.identity == MissionFixtures.issue().identity)
        #expect(aggregate.primaryLeg?.projectId == project.id)
    }

    private static let project = ProjectConfig(
        id: "project-1",
        name: "Alas",
        path: "/tmp/alas",
        color: "teal",
        addedAt: Date(timeIntervalSince1970: 100)
    )

    private static let worktree = Worktree(
        id: "worktree-1",
        projectId: "project-1",
        name: "fix/parser-crash",
        branch: "fix/parser-crash",
        path: URL(fileURLWithPath: "/tmp/alas-mission"),
        status: .clean,
        lastActivity: Date(timeIntervalSince1970: 100)
    )

    private static func makeMissionPersistence() throws -> MissionPersistence {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        aggregate.mission.setupCheckpoint = .running
        aggregate.legs[0].worktreeId = worktree.id
        aggregate.legs[0].acpSessionId = "session-1"
        aggregate.legs[0].pendingInitialPrompt = nil
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-state-mission-\(UUID().uuidString).sqlite")
            .path
        let store = try MissionStore(path: path)
        try store.insert(aggregate)
        return MissionPersistence(path: path)
    }

    private static func waitForMissionState(
        _ state: MissionState,
        persistence: MissionPersistence
    ) async throws -> MissionAggregate {
        for _ in 0..<100 {
            if let aggregate = try await persistence.aggregate(id: MissionID(rawValue: "mission-1")),
               aggregate.mission.state == state {
                return aggregate
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(try await persistence.aggregate(id: MissionID(rawValue: "mission-1")))
    }
}
