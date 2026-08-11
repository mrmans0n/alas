import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct IssueWorktreeLaunchTests {
    private static let promptID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test func chatLaunchCreatesAcpTabQueuesEditedPromptOnceAndPersistsAttachment() async throws {
        let fixture = try await WorktreeLaunchFixture(name: "chat")
        defer { fixture.cleanup() }
        let prepared = Self.preparedPrompt()
        let attachment = Self.attachment()

        let id = try await fixture.create(
            branch: "issue-chat",
            launchSurface: .acp(agentId: "missing-acp-agent", preparedPrompt: prepared),
            issueAttachment: attachment
        )

        #expect(fixture.state.projectsManager.issueAttachment(
            projectId: fixture.project.id,
            worktreeId: id
        ) == attachment)
        #expect(fixture.store.writtenProjectsFile?.projects.first?.issueAttachments[id] == attachment)
        #expect(Self.acpTabs(in: fixture.state, worktreeId: id).map(\.sessionId) == [prepared.sessionID])

        let manager = try #require(fixture.state.acpManager(forWorktreeId: id))
        let session = try #require(manager.liveSession(for: prepared.sessionID))
        #expect(session.queue.map(\.id) == [prepared.promptID])
        #expect(session.queue.first.map { ACPSessionRunner.textPreview(of: $0.blocks) } == prepared.text)

        let persisted = ACPSessionPersistence(path: Paths.acpSessionsDB(forWorktreeId: id).path)
        #expect(try await persisted.loadSession(id: prepared.sessionID)?.agentId == "missing-acp-agent")
        #expect(try await persisted.loadQueue(sessionId: prepared.sessionID).map(\.id) == [prepared.promptID])
    }

    @Test func retryWithSamePreparedPromptDoesNotDuplicateTheQueuedPrompt() async throws {
        let fixture = try await WorktreeLaunchFixture(name: "retry")
        defer { fixture.cleanup() }
        let prepared = Self.preparedPrompt()
        let id = try await fixture.create(
            branch: "issue-retry",
            launchSurface: .acp(agentId: "missing-acp-agent", preparedPrompt: prepared),
            issueAttachment: Self.attachment()
        )
        let worktree = try #require(fixture.state.worktree(withId: id))

        try? await fixture.state.startACPSession(
            worktree: worktree,
            sessionID: prepared.sessionID,
            agentID: "missing-acp-agent",
            promptID: prepared.promptID,
            prompt: prepared.text
        )

        let manager = try #require(fixture.state.acpManager(forWorktreeId: id))
        let session = try #require(manager.liveSession(for: prepared.sessionID))
        #expect(session.queue.map(\.id) == [prepared.promptID])
        let persisted = ACPSessionPersistence(path: Paths.acpSessionsDB(forWorktreeId: id).path)
        #expect(try await persisted.loadQueue(sessionId: prepared.sessionID).map(\.id) == [prepared.promptID])
    }

    @Test func terminalLaunchPersistsAttachmentWithoutCreatingAcpPrompt() async throws {
        let fixture = try await WorktreeLaunchFixture(name: "terminal")
        defer { fixture.cleanup() }
        let attachment = Self.attachment()

        let id = try await fixture.create(
            branch: "issue-terminal",
            launchSurface: .terminal(agentId: nil),
            issueAttachment: attachment
        )

        #expect(fixture.state.projectsManager.issueAttachment(
            projectId: fixture.project.id,
            worktreeId: id
        ) == attachment)
        #expect(Self.acpTabs(in: fixture.state, worktreeId: id).isEmpty)
        #expect(fixture.state.acpManager(forWorktreeId: id) == nil)
    }

    @Test func noTabLaunchPersistsAttachmentWithoutCreatingAcpPrompt() async throws {
        let fixture = try await WorktreeLaunchFixture(name: "none")
        defer { fixture.cleanup() }
        let attachment = Self.attachment()

        let id = try await fixture.create(
            branch: "issue-none",
            launchSurface: .none,
            issueAttachment: attachment
        )

        #expect(fixture.state.projectsManager.issueAttachment(
            projectId: fixture.project.id,
            worktreeId: id
        ) == attachment)
        #expect(fixture.state.tabs.tabs(forWorktree: id).isEmpty)
        #expect(fixture.state.acpManager(forWorktreeId: id) == nil)
    }

    @Test func reloadRestoresAttachmentAndPreparedAcpState() async throws {
        let fixture = try await WorktreeLaunchFixture(name: "reload")
        defer { fixture.cleanup() }
        let prepared = Self.preparedPrompt()
        let attachment = Self.attachment()
        let id = try await fixture.create(
            branch: "issue-reload",
            launchSurface: .acp(agentId: "missing-acp-agent", preparedPrompt: prepared),
            issueAttachment: attachment
        )
        let persistedProjects = try #require(fixture.store.writtenProjectsFile)
        let reloadedStore = WorktreeLaunchFixture.Store(initialProjectsFile: persistedProjects)
        let tabsManager = TabsManager(
            store: fixture.store,
            tabsDirectory: fixture.tabsDirectory
        )
        let reloaded = AppState(store: reloadedStore, tabsManager: tabsManager)
        try await reloaded.projectsManager.refreshWorktrees(projectId: fixture.project.id)
        reloaded.tabs.loadAll(worktreeIds: [id])

        #expect(reloaded.projectsManager.issueAttachment(
            projectId: fixture.project.id,
            worktreeId: id
        ) == attachment)
        #expect(Self.acpTabs(in: reloaded, worktreeId: id).map(\.sessionId) == [prepared.sessionID])

        let worktree = try #require(reloaded.worktree(withId: id))
        let manager = try #require(reloaded.acpManager(for: worktree))
        #expect(await manager.persistedSessionRow(id: prepared.sessionID) != nil)
        _ = manager.placeholderSession(id: prepared.sessionID)
        await manager.hydrateIfNeeded(id: prepared.sessionID)
        let session = try #require(manager.liveSession(for: prepared.sessionID))
        #expect(session.queue.map(\.id) == [prepared.promptID])
    }

    @Test func dialogBuildsPreparedPromptOnlyForFinalChatSelection() {
        var calls = 0
        let draft = AttachedIssueDraft(
            source: IssueSnapshot(
                identity: .init(providerID: .manual, stableID: "issue-42"),
                canonicalURL: URL(string: "https://example.com/issues/42")!,
                providerLabel: "example.com",
                displayReference: "#42",
                repositoryLocator: nil,
                title: "Fix sync",
                body: "Issue context",
                state: .unknown,
                labels: [],
                assignees: [],
                providerUpdatedAt: nil,
                capturedAt: .distantPast,
                refreshError: nil,
                contentOrigin: .manual,
                isEditable: true,
                isRefreshable: false
            ),
            projectID: nil,
            branchSeed: "feature/42-fix-sync",
            prompt: "Use the edited prompt."
        )

        let chat = NewWorktreeDialog.launchSurfaceForCreate(
            openAfterCreate: true,
            launchMode: .acp,
            launchAgentId: "claude",
            issueDraft: draft,
            makePreparedPrompt: {
                calls += 1
                return PreparedWorktreeACPPrompt(
                    sessionID: "issue-session",
                    promptID: Self.promptID,
                    text: $0
                )
            }
        )
        let terminal = NewWorktreeDialog.launchSurfaceForCreate(
            openAfterCreate: true,
            launchMode: .terminal,
            launchAgentId: "claude",
            issueDraft: draft,
            makePreparedPrompt: {
                calls += 1
                return PreparedWorktreeACPPrompt(sessionID: "unused", promptID: UUID(), text: $0)
            }
        )
        let none = NewWorktreeDialog.launchSurfaceForCreate(
            openAfterCreate: false,
            launchMode: .acp,
            launchAgentId: "claude",
            issueDraft: draft,
            makePreparedPrompt: {
                calls += 1
                return PreparedWorktreeACPPrompt(sessionID: "unused", promptID: UUID(), text: $0)
            }
        )

        #expect(chat == .acp(
            agentId: "claude",
            preparedPrompt: PreparedWorktreeACPPrompt(
                sessionID: "issue-session",
                promptID: Self.promptID,
                text: "Use the edited prompt."
            )
        ))
        #expect(terminal == .terminal(agentId: "claude"))
        #expect(none == .none)
        #expect(calls == 1)
    }

    private static func preparedPrompt() -> PreparedWorktreeACPPrompt {
        PreparedWorktreeACPPrompt(
            sessionID: "issue-session",
            promptID: promptID,
            text: "Fix the parser crash from GitHub issue #42."
        )
    }

    private static func attachment() -> IssueAttachment {
        IssueAttachment(
            canonicalURL: URL(string: "https://github.com/acme/alas/issues/42")!,
            providerLabel: "GitHub",
            displayReference: "#42",
            title: "Fix parser crash"
        )
    }

    private static func acpTabs(in state: AppState, worktreeId: String) -> [ACPSessionTabState] {
        state.tabs.tabs(forWorktree: worktreeId).compactMap {
            if case .acpSession(let tab) = $0 { return tab }
            return nil
        }
    }
}

@MainActor
private final class WorktreeLaunchFixture {
    final class Store: PersistenceStoreProtocol, @unchecked Sendable {
        let initialProjectsFile: ProjectsFile
        var writtenProjectsFile: ProjectsFile?
        var writtenTabs: [String: TabsFile] = [:]

        init(initialProjectsFile: ProjectsFile = ProjectsFile(projects: [])) {
            self.initialProjectsFile = initialProjectsFile
        }

        func write<T: Encodable>(_ value: T, to url: URL) throws {
            if let projectsFile = value as? ProjectsFile {
                writtenProjectsFile = projectsFile
            }
            if let tabsFile = value as? TabsFile {
                writtenTabs[url.lastPathComponent] = tabsFile
            }
        }

        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
            if type == ProjectsFile.self { return initialProjectsFile as? T }
            if type == TabsFile.self { return writtenTabs[url.lastPathComponent] as? T }
            return nil
        }
    }

    let root: URL
    let repo: URL
    let tabsDirectory: URL
    let store: Store
    let state: AppState
    let project: ProjectConfig

    init(name: String) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-issue-worktree-launch-\(name)-\(UUID().uuidString)", isDirectory: true)
        repo = root.appendingPathComponent("repo", isDirectory: true)
        tabsDirectory = root.appendingPathComponent("tabs", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tabsDirectory, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)

        store = Store()
        state = AppState(
            store: store,
            tabsManager: TabsManager(store: store, tabsDirectory: tabsDirectory)
        )
        project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "repo-\(name)",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
    }

    func create(
        branch: String,
        launchSurface: WorktreeLaunchSurface,
        issueAttachment: IssueAttachment
    ) async throws -> String {
        let destination = root.appendingPathComponent(branch, isDirectory: true)
        let id = await state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: branch,
            destination: destination,
            runStartup: false,
            launchSurface: launchSurface,
            issueAttachment: issueAttachment
        )
        #expect(!id.isEmpty)
        try await waitForOperationToClear(id: id)
        return id
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private func waitForOperationToClear(id: String, timeoutSeconds: Double = 10) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if state.projectsManager.operationState(for: id) == nil { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Timed out waiting for operationState to clear for id \(id)")
    }
}
