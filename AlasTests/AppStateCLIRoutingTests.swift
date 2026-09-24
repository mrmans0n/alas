import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateCLIRoutingTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        var projectsFile: ProjectsFile = .init(projects: [])

        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            if type == ProjectsFile.self { return projectsFile as? T }
            if type == AppConfig.self { return AppConfig.defaults as? T }
            return nil
        }
    }

    private func makeRepo(name: String, initialBranch: String = "main") async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cli-appstate-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", initialBranch], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    private func makeStateWithWorktree(
        name: String,
        initialBranch: String = "main"
    ) async throws -> (AppState, ProjectConfig, Worktree) {
        let repo = try await makeRepo(name: name, initialBranch: initialBranch)
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "test", color: "#000000")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let worktree = try #require(state.projectsManager.worktrees(projectId: project.id).first)
        return (state, project, worktree)
    }

    private func makeStateWithSharedPathWorktrees(
        id: String,
        orchestrationPersistence: ACPOrchestrationPersistence
    ) -> (AppState, ProjectConfig, ProjectConfig, Worktree, Worktree) {
        let projectA = ProjectConfig(
            id: "recovery-a-\(UUID().uuidString)", name: "A", path: "/repos/recovery-a",
            color: "blue", addedAt: .distantPast
        )
        let projectB = ProjectConfig(
            id: "recovery-b-\(UUID().uuidString)", name: "B", path: "/repos/recovery-b",
            color: "green", addedAt: .distantPast, host: "project-b-host"
        )
        let state = AppState(
            store: MemoryStore(projectsFile: ProjectsFile(projects: [projectA, projectB])),
            runHistoryStore: nil,
            acpOrchestrationPersistence: orchestrationPersistence,
            restoreActiveTabsOnStartup: false
        )
        let path = URL(fileURLWithPath: id)
        let worktreeA = Worktree(
            id: id, projectId: projectA.id, name: "shared", branch: "shared",
            path: path, status: .clean, lastActivity: .distantPast
        )
        let worktreeB = Worktree(
            id: id, projectId: projectB.id, name: "shared", branch: "shared",
            path: path, status: .clean, lastActivity: .distantPast
        )
        state.projectsManager.insertOptimisticWorktree(worktreeA)
        state.projectsManager.insertOptimisticWorktree(worktreeB)
        return (state, projectA, projectB, worktreeA, worktreeB)
    }

    private func removeACPDatabaseFiles(projects: [ProjectConfig], worktreeID: String) {
        let paths = projects.map { Paths.acpSessionsDB(forProjectId: $0.id, worktreeId: worktreeID).path }
            + [Paths.acpSessionsDB(forWorktreeId: worktreeID).path]
        for path in paths {
            for suffix in ["", "-wal", "-shm", ".owner"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
    }

    @Test func makeCLICommandRouterUsesTerminalRegistryAndTabs() async throws {
        let repo = try await makeRepo(name: "router")
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("a.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)

        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "test", color: "#000000")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let worktree = try #require(state.projectsManager.worktrees(projectId: project.id).first)
        state.selectedWorktreeId = worktree.id

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { sessionId in
            sessionId == "s1" ? worktree.id : nil
        })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [file.path])))

        #expect(response == .ok)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let editor) = $0 { return editor.relativePath == "a.txt" }
            return false
        })
    }

    @Test func cliOpenLineRangeRevealsTheRequestedEditorLines() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "open-line-range")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let file = worktree.path.appendingPathComponent("a.txt")
        try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in worktree.id })

        let response = await router.handle(.init(
            version: 1,
            sessionId: "s1",
            cwd: nil,
            command: .openAt(path: file.path, line: 2, endLine: 3)
        ))

        #expect(response == .ok)
        let editor = try #require(state.tabs.tabs(forWorktree: worktree.id).compactMap { tab -> EditorTabState? in
            guard case .editor(let editor) = tab else { return nil }
            return editor
        }.first)
        #expect(editor.revealLine == 1)
        #expect(editor.revealEndLine == 2)
    }

    @Test func checkoutOwnedCLIUsesOwnerQualifiedCwdResolution() async throws {
        let sharedPath = URL(fileURLWithPath: "/srv/shared/member")
        let local = Worktree(
            id: "local-id",
            projectId: "local-project",
            name: "local",
            branch: "main",
            path: sharedPath,
            status: .clean,
            lastActivity: Date()
        )
        let remote = Worktree(
            id: "remote-id",
            projectId: "remote-project",
            name: "remote",
            branch: "main",
            path: sharedPath,
            status: .clean,
            lastActivity: Date()
        )
        let owner = SessionOwnerID.workspaceCheckout(
            UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            .ssh("devbox")
        )
        let router = AlasCLICommandRouter(
            sessionWorktreeId: { _ in nil },
            sessionCwdWorktree: { sessionId, cwd in
                sessionId == "checkout-leaf" && cwd == sharedPath.appendingPathComponent("subdir").path ? remote : nil
            },
            originatingWorktree: { id in [local, remote].first(where: { $0.id == id }) },
            visibleWorktrees: { [local, remote] },
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            activateApp: {}
        )

        let response = await router.handle(.init(
            version: 1,
            sessionId: "checkout-leaf",
            cwd: sharedPath.appendingPathComponent("subdir").path,
            command: .worktree(.list)
        ))

        guard case .text(let rows) = response else {
            Issue.record("Expected worktree list response")
            return
        }
        #expect(owner.storageKey.hasPrefix("workspace-checkout--"))
        #expect(rows == AlasCLIWorktreeResolver.rows(worktrees: [remote], currentWorktreeId: remote.id))
    }

    @Test func checkoutOwnedLocalCwdResolvesSymlinksBeforeSelectingMember() async throws {
        let repo = try await makeRepo(name: "checkout-cwd-symlink")
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-cwd-symlink-\(UUID().uuidString).json")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-cwd-outside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: workspaceURL)
            try? FileManager.default.removeItem(at: outside)
        }
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let manager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        _ = await manager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "space", spaces: [
            SpaceConfig(id: "space", name: "Default", emoji: "folder", projectIds: [], lastSelectedWorktreeId: nil, createdAt: .distantPast)
        ]))
        let routedState = AppState(
            store: MemoryStore(),
            workspacesManager: manager,
            workspaceStore: workspaceStore
        )
        let project = try await routedState.projectsManager.addProject(path: repo, displayName: "test", color: "#000000")
        try await routedState.projectsManager.refreshWorktrees(projectId: project.id)
        let worktree = try #require(routedState.projectsManager.worktrees(projectId: project.id).first)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        let link = worktree.path.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let memberID = UUID()
        let checkout = WorkspaceCheckout(
            workspaceID: UUID(),
            fallbackWorkspaceName: "Shared",
            executionLocation: .local,
            branch: "feature/shared",
            rootPath: worktree.path.deletingLastPathComponent().path,
            operation: .idle,
            members: [
                WorkspaceCheckoutMember(
                    id: memberID,
                    workspaceMemberID: UUID(),
                    projectID: worktree.projectId,
                    fallbackProjectName: "Project",
                    fallbackRepositoryRoot: worktree.path.path,
                    worktreePath: worktree.path.path,
                    availability: .available
                )
            ]
        )
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
        await manager.refreshCheckoutSnapshots()
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let router = routedState.makeCLICommandRouter(
            sessionWorktreeLookup: { _ -> String? in nil },
            sessionOwnerLookup: { $0 == "checkout-leaf" ? owner : nil }
        )

        let response = await router.handle(.init(
            version: 1,
            sessionId: "checkout-leaf",
            cwd: link.appendingPathComponent("subdir").path,
            command: AlasCLIRequest.Command.resolve
        ))

        #expect(response == .error("Unknown Alas terminal session."))
    }

    @Test func checkoutOwnedRemoteCwdUsesHostPhysicalPathBeforeSelectingMember() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-remote-cwd-symlink-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: workspaceURL) }
        let project = ProjectConfig(
            id: "remote-project",
            name: "Remote",
            path: "/repo",
            color: "#000000",
            addedAt: .distantPast,
            host: "devbox"
        )
        let workspaceStore = WorkspaceStore(url: workspaceURL)
        let manager = WorkspacesManager(bridge: WorkspaceSpacePersistenceBridge(workspaceStore: workspaceStore))
        let checkout = WorkspaceCheckout(
            workspaceID: UUID(),
            fallbackWorkspaceName: "Shared",
            executionLocation: .ssh("devbox"),
            branch: "feature/shared",
            rootPath: "/checkout",
            operation: .idle,
            members: [
                WorkspaceCheckoutMember(
                    id: UUID(),
                    workspaceMemberID: UUID(),
                    projectID: project.id,
                    fallbackProjectName: "Remote",
                    fallbackRepositoryRoot: project.path,
                    worktreePath: "/checkout/member",
                    availability: .available
                )
            ]
        )
        try await workspaceStore.checkpoint(.init(checkouts: [checkout]))
        _ = await manager.setEnabled(true, spacesFile: SpacesFile(activeSpaceId: "space", spaces: [
            SpaceConfig(id: "space", name: "Default", emoji: "folder", projectIds: [project.id], lastSelectedWorktreeId: nil, createdAt: .distantPast)
        ]))
        let remote = WorkspaceRemoteTransport { _, args, _ in
            let command = args.joined(separator: " ")
            if command.contains("/checkout/member/link/subdir") {
                return .init(exitCode: 0, stdout: "/outside/subdir\n", stderr: "")
            }
            if command.contains("/checkout/member") {
                return .init(exitCode: 0, stdout: "/checkout/member\n", stderr: "")
            }
            return .init(exitCode: 1, stdout: "", stderr: "missing")
        }
        let state = AppState(
            store: MemoryStore(projectsFile: .init(projects: [project])),
            workspacesManager: manager,
            workspaceStore: workspaceStore,
            workspaceRemoteTransport: remote
        )
        state.projectsManager.insertOptimisticWorktree(Worktree(
            id: "remote-worktree",
            projectId: project.id,
            name: "member",
            branch: "main",
            path: URL(fileURLWithPath: "/checkout/member"),
            status: .clean,
            lastActivity: .distantPast
        ))
        let owner = SessionOwnerID.workspaceCheckout(checkout.id, checkout.executionLocation)
        let router = state.makeCLICommandRouter(
            sessionWorktreeLookup: { _ -> String? in nil },
            sessionOwnerLookup: { $0 == "checkout-leaf" ? owner : nil }
        )

        let response = await router.handle(.init(
            version: 1,
            sessionId: "checkout-leaf",
            cwd: "/checkout/member/link/subdir",
            command: AlasCLIRequest.Command.resolve
        ))

        #expect(response == .error("Unknown Alas terminal session."))
    }

    @Test func startHarnessCLIRequestUsesRealTerminalRegistry() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "socket-callback")
        defer {
            state.harness.socketServer.shutdown()
            try? FileManager.default.removeItem(at: worktree.path)
        }
        let file = worktree.path.appendingPathComponent("from-socket.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        let session = TerminalSession(
            id: "s1",
            worktreeId: worktree.id,
            projectId: project.id,
            surface: surface,
            executable: "/bin/zsh",
            args: []
        )
        state.terminal.registry.register(session)
        state.startHarness()

        let handler = try #require(state.harness.socketServer.onCLIRequest)
        let response = await handler(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [file.path])))

        #expect(response == .ok)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let editor) = $0 { return editor.relativePath == "from-socket.txt" }
            return false
        })
    }

    @Test func terminalPreviewAutomationUsesTheProjectOwnedPreview() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "terminal-preview-owner")
        defer {
            state.harness.socketServer.shutdown()
            try? FileManager.default.removeItem(at: worktree.path)
        }
        let sessionID = "terminal-preview-owner-session"
        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        let session = TerminalSession(
            id: sessionID,
            worktreeId: worktree.id,
            projectId: project.id,
            surface: surface,
            executable: "/bin/zsh",
            args: []
        )
        state.terminal.registry.register(session)
        _ = state.tabs.appendTerminal(
            worktreeId: worktree.id,
            projectId: project.id,
            title: "Shell",
            sessionId: sessionID
        )
        let owner = SessionOwnerID.projectWorktree(projectId: project.id, worktreeId: worktree.id)
        _ = state.tabs.openWebPreview(owner: owner)
        state.startHarness()

        let handler = try #require(state.harness.socketServer.onCLIRequest)
        let listResponse = await handler(.init(
            version: 1,
            sessionId: sessionID,
            cwd: nil,
            command: .preview(.init(action: .list))
        ))
        guard case .text(let listLines) = listResponse,
              let listJSON = listLines.first?.data(using: .utf8),
              let listPayload = try JSONSerialization.jsonObject(with: listJSON) as? [String: Any],
              let previews = listPayload["previews"] as? [[String: Any]]
        else {
            Issue.record("A worktree terminal should be able to list its project's existing preview")
            return
        }
        #expect(previews.count == 1)
        #expect(previews.first?["tab_id"] as? String == "web-preview:\(worktree.id)")

        let response = await handler(.init(
            version: 1,
            sessionId: sessionID,
            cwd: nil,
            command: .preview(.init(action: .open))
        ))

        guard case .text(let lines) = response,
              let json = lines.first?.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        else {
            Issue.record("A worktree terminal should be able to focus its project's existing preview")
            return
        }
        #expect(payload["tab_id"] as? String == "web-preview:\(worktree.id)")
    }

    @Test func persistedTerminalPreviewAutomationUsesTheProjectOwnedPreview() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "persisted-terminal-preview-owner")
        defer {
            state.harness.socketServer.shutdown()
            try? FileManager.default.removeItem(at: worktree.path)
        }
        let sessionID = "persisted-terminal-preview-owner-session"
        _ = state.tabs.appendTerminal(
            worktreeId: worktree.id,
            projectId: project.id,
            title: "Shell",
            sessionId: sessionID
        )
        let owner = SessionOwnerID.projectWorktree(projectId: project.id, worktreeId: worktree.id)
        _ = state.tabs.openWebPreview(owner: owner)
        state.startHarness()

        let handler = try #require(state.harness.socketServer.onCLIRequest)
        let response = await handler(.init(
            version: 1,
            sessionId: sessionID,
            cwd: nil,
            command: .preview(.init(action: .open))
        ))

        guard case .text(let lines) = response,
              let json = lines.first?.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        else {
            Issue.record("A persisted terminal should be able to focus its project's existing preview")
            return
        }
        #expect(payload["tab_id"] as? String == "web-preview:\(worktree.id)")
    }

    @Test func harnessSessionLocationResolvesLiveACPSession() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "live-acp-harness-location")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let manager = try #require(state.acpManager(for: worktree))
        let session = manager.createSession(agentId: "pi")

        let location = state.harnessSessionLocation(sessionId: session.id)

        #expect(location?.projectId == project.id)
        #expect(location?.worktreeId == worktree.id)
    }

    @Test func acpCLIOriginKeepsProjectForSamePathWorktrees() async throws {
        let sharedID = "/tmp/alas-cli-shared-\(UUID().uuidString)"
        let legacyDB = Paths.acpSessionsDB(forWorktreeId: sharedID)
        let firstProject = ProjectConfig(
            id: "first-\(UUID().uuidString)", name: "First", path: "/repos/first",
            color: "blue", addedAt: .distantPast
        )
        let secondProject = ProjectConfig(
            id: "second-\(UUID().uuidString)", name: "Second", path: "/repos/second",
            color: "green", addedAt: .distantPast
        )
        defer {
            for path in [legacyDB.path, Paths.acpSessionsDB(forProjectId: secondProject.id, worktreeId: sharedID).path] {
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(atPath: path + suffix)
                }
            }
            try? FileManager.default.removeItem(atPath: legacyDB.path + ".owner")
        }
        let state = AppState(store: MemoryStore(
            projectsFile: ProjectsFile(projects: [firstProject, secondProject])
        ))
        let first = Worktree(
            id: sharedID, projectId: firstProject.id, name: "first", branch: "first",
            path: URL(fileURLWithPath: sharedID), status: .clean, lastActivity: .distantPast
        )
        let second = Worktree(
            id: sharedID, projectId: secondProject.id, name: "second", branch: "second",
            path: URL(fileURLWithPath: sharedID), status: .clean, lastActivity: .distantPast
        )
        state.projectsManager.insertOptimisticWorktree(first)
        state.projectsManager.insertOptimisticWorktree(second)
        let manager = try #require(state.acpManager(for: second))
        let session = manager.createSession(agentId: "pi")
        let router = state.makeCLICommandRouter(
            sessionWorktreeLookup: { $0 == session.id ? sharedID : nil },
            sessionOwnerLookup: { $0 == session.id ? manager.owner : nil }
        )

        let response = await router.handle(.init(
            version: 1, sessionId: session.id, cwd: nil, command: .worktree(.list)
        ))

        #expect(response == .text(AlasCLIWorktreeResolver.rows(worktrees: [second], currentWorktreeId: sharedID)))
        #expect(router.resolveACPSessionOrigin(session.id)?.projectId == secondProject.id)
    }

    @Test func interruptedDelegationRecoveryUsesTheRecordedProjectForSharedWorktreeIDs() async throws {
        let sharedID = "/tmp/alas-recovery-shared-\(UUID().uuidString)"
        let orchestrationPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-orchestration-recovery-\(UUID().uuidString).sqlite")
        let persistence = ACPOrchestrationPersistence(path: orchestrationPath.path)
        let (state, projectA, projectB, worktreeA, worktreeB) = makeStateWithSharedPathWorktrees(
            id: sharedID,
            orchestrationPersistence: persistence
        )
        defer { removeACPDatabaseFiles(projects: [projectA, projectB], worktreeID: sharedID) }
        let childSessionID = "recovery-child-\(UUID().uuidString)"
        try await persistence.insert(ACPDelegationRecord(
            childSessionId: childSessionID,
            parentSessionId: "recovery-parent-\(UUID().uuidString)",
            projectId: projectB.id,
            parentWorktreeId: sharedID,
            childWorktreeId: sharedID,
            agentId: "pi",
            worktreeRequest: .current(worktreeId: sharedID),
            pendingInitialPrompt: nil,
            phase: .starting,
            failureMessage: nil,
            createdAt: 1,
            updatedAt: 1
        ))

        await state.reconcileInterruptedDelegations()

        let managerB = try #require(state.acpManager(for: worktreeB))
        #expect(await managerB.persistedSessionRow(id: childSessionID) != nil)
        await state.acpManager(for: worktreeA)?.flushAllPersistence()
        await managerB.flushAllPersistence()
    }

    @Test func openingFileBySelectedSharedWorktreeIdPreservesItsProjectOwner() throws {
        let sharedID = "/tmp/alas-open-file-shared-\(UUID().uuidString)"
        let orchestrationPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-open-file-orchestration-\(UUID().uuidString).sqlite")
        let persistence = ACPOrchestrationPersistence(path: orchestrationPath.path)
        let (state, _, projectB, _, worktreeB) = makeStateWithSharedPathWorktrees(
            id: sharedID,
            orchestrationPersistence: persistence
        )

        state.focusGlobalWorktree(id: sharedID, projectId: projectB.id)
        state.openFile(relativePath: "README.md", worktreeId: sharedID)

        #expect(state.selectedWorktreeProjectId == projectB.id)
        #expect(state.projectsManager.worktrees(projectId: projectB.id).contains(worktreeB))
    }

    @Test func persistedDelegatedSessionLookupEnumeratesSamePathProjects() async throws {
        let sharedID = "/tmp/alas-recovery-lookup-shared-\(UUID().uuidString)"
        let orchestrationPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-orchestration-lookup-\(UUID().uuidString).sqlite")
        let persistence = ACPOrchestrationPersistence(path: orchestrationPath.path)
        let (state, projectA, projectB, _, worktreeB) = makeStateWithSharedPathWorktrees(
            id: sharedID,
            orchestrationPersistence: persistence
        )
        defer { removeACPDatabaseFiles(projects: [projectA, projectB], worktreeID: sharedID) }
        let childSessionID = "recovery-lookup-child-\(UUID().uuidString)"
        let managerB = try #require(state.acpManager(for: worktreeB))
        _ = managerB.createSession(id: childSessionID, agentId: "pi")
        await managerB.flushAllPersistence()

        let resolved = await state.acpManagerForPersistedSession(
            sessionId: childSessionID,
            preferredProjectId: projectB.id,
            preferredWorktreeId: sharedID
        )

        #expect(resolved === managerB)
    }

    @Test func routeTerminalOpenURLResolvesRelativePathAgainstShellCwd() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "ghostty-relative")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let subdir = worktree.path.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let file = subdir.appendingPathComponent("plan.md")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        surface.setCurrentWorkingDirectory(subdir)
        let session = TerminalSession(
            id: "s1", worktreeId: worktree.id, projectId: project.id,
            surface: surface, executable: "/bin/zsh", args: []
        )
        state.terminal.registry.register(session)

        let handled = state.routeTerminalOpenURL(rawURL: "plan.md", sessionId: "s1")

        #expect(handled == true)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let s) = $0 { return s.relativePath == "notes/plan.md" && !s.isExternal }
            return false
        })
    }

    @Test func routeTerminalOpenURLResolvesRelativePathWithLineAndColumn() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "ghostty-relative-position")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let subdir = worktree.path.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let file = subdir.appendingPathComponent("plan.md")
        try "first\nsecond\nthird\n".write(to: file, atomically: true, encoding: .utf8)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        surface.setCurrentWorkingDirectory(subdir)
        let session = TerminalSession(
            id: "s1", worktreeId: worktree.id, projectId: project.id,
            surface: surface, executable: "/bin/zsh", args: []
        )
        state.terminal.registry.register(session)

        let handled = state.routeTerminalOpenURL(rawURL: "plan.md:2:4", sessionId: "s1")

        #expect(handled == true)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let s) = $0 {
                return s.relativePath == "notes/plan.md"
                    && s.revealLine == 1
                    && s.revealCharacter == 3
                    && !s.isExternal
            }
            return false
        })
    }

    @Test func routeTerminalOpenURLAcceptsAbsolutePathInsideWorkspace() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "ghostty-absolute")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let file = worktree.path.appendingPathComponent("README.md")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        let session = TerminalSession(
            id: "s1", worktreeId: worktree.id, projectId: project.id,
            surface: surface, executable: "/bin/zsh", args: []
        )
        state.terminal.registry.register(session)

        let handled = state.routeTerminalOpenURL(rawURL: file.path, sessionId: "s1")

        #expect(handled == true)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let s) = $0 { return s.relativePath == "README.md" && !s.isExternal }
            return false
        })
    }

    @Test func routeTerminalOpenURLAcceptsAbsolutePathWithLine() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "ghostty-absolute-position")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let file = worktree.path.appendingPathComponent("README.md")
        try "first\nsecond\n".write(to: file, atomically: true, encoding: .utf8)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        let session = TerminalSession(
            id: "s1", worktreeId: worktree.id, projectId: project.id,
            surface: surface, executable: "/bin/zsh", args: []
        )
        state.terminal.registry.register(session)

        let handled = state.routeTerminalOpenURL(rawURL: "\(file.path):2", sessionId: "s1")

        #expect(handled == true)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let s) = $0 {
                return s.relativePath == "README.md"
                    && s.revealLine == 1
                    && s.revealCharacter == 0
                    && !s.isExternal
            }
            return false
        })
    }

    @Test func routeTerminalOpenURLAcceptsFileURLInsideWorkspace() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "ghostty-fileurl")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let file = worktree.path.appendingPathComponent("README.md")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        let session = TerminalSession(
            id: "s1", worktreeId: worktree.id, projectId: project.id,
            surface: surface, executable: "/bin/zsh", args: []
        )
        state.terminal.registry.register(session)

        let handled = state.routeTerminalOpenURL(rawURL: file.absoluteURL.absoluteString, sessionId: "s1")

        #expect(handled == true)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let s) = $0 { return s.relativePath == "README.md" }
            return false
        })
    }

    @Test func routeTranscriptOpenURLAcceptsAbsoluteMarkdownPathWithLine() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "transcript-absolute-position")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let dir = worktree.path.appendingPathComponent("docs/design")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("spec.md")
        try "first\nsecond\n".write(to: file, atomically: true, encoding: .utf8)

        let route = state.transcriptLinkRoute(
            URL(string: "\(file.path):2")!,
            worktreeId: worktree.id
        )

        #expect(route == .opened)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let s) = $0 {
                return s.relativePath == "docs/design/spec.md"
                    && s.revealLine == 1
                    && s.revealCharacter == 0
                    && !s.isExternal
            }
            return false
        })
    }

    @Test func routeTranscriptOpenURLAcceptsRootRelativePathWithLineParsedAsScheme() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "transcript-root-position")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let file = worktree.path.appendingPathComponent("Package.swift")
        try "first\nsecond\n".write(to: file, atomically: true, encoding: .utf8)

        let route = state.transcriptLinkRoute(
            URL(string: "Package.swift:2")!,
            worktreeId: worktree.id
        )

        #expect(route == .opened)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let s) = $0 {
                return s.relativePath == "Package.swift"
                    && s.revealLine == 1
                    && s.revealCharacter == 0
                    && !s.isExternal
            }
            return false
        })
    }

    @Test func routeTranscriptOpenURLOpensAbsolutePathInAnotherWorktree() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "transcript-sibling")
        let siblingPath = worktree.path.deletingLastPathComponent()
            .appendingPathComponent("transcript-sibling-other-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: worktree.path)
            try? FileManager.default.removeItem(at: siblingPath)
        }
        state.selectedWorktreeId = worktree.id
        _ = try await Process.git(
            ["worktree", "add", "-q", "-b", "transcript-sibling-other", siblingPath.path, "main"],
            cwd: worktree.path
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let sibling = try #require(
            state.projectsManager.worktrees(projectId: project.id)
                .first { $0.branch == "transcript-sibling-other" }
        )
        let file = sibling.path.appendingPathComponent("PLAN.md")
        try "first\nsecond\n".write(to: file, atomically: true, encoding: .utf8)

        let route = state.transcriptLinkRoute(
            URL(string: "\(file.path):2")!,
            worktreeId: worktree.id
        )

        #expect(route == .opened)
        #expect(state.selectedWorktreeId == sibling.id)
        #expect(state.tabs.tabs(forWorktree: sibling.id).contains {
            if case .editor(let s) = $0 {
                return s.relativePath == "PLAN.md" && s.revealLine == 1 && !s.isExternal
            }
            return false
        })
        #expect(state.tabs.tabs(forWorktree: worktree.id).allSatisfy {
            if case .editor = $0 { return false }
            return true
        })
    }

    @Test func routeTranscriptOpenURLHandsOutsideFileToTheSystemAsAFileURL() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "transcript-outside")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let externalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-transcript-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDir) }
        let file = externalDir.appendingPathComponent("notes.md")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)

        let route = state.transcriptLinkRoute(URL(string: file.path)!, worktreeId: worktree.id)

        #expect(route == .systemOpen(file.standardizedFileURL))
        #expect(state.tabs.tabs(forWorktree: worktree.id).allSatisfy {
            if case .editor = $0 { return false }
            return true
        })
    }

    @Test func routeTranscriptOpenURLIsUnhandledForMissingAbsolutePath() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "transcript-missing")
        defer { try? FileManager.default.removeItem(at: worktree.path) }

        let route = state.transcriptLinkRoute(
            URL(string: worktree.path.appendingPathComponent("nope.md").path)!,
            worktreeId: worktree.id
        )

        #expect(route == .unhandled)
    }

    @Test func routeTerminalOpenURLReturnsFalseForPathOutsideWorkspace() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "ghostty-outside")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let externalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ghostty-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDir) }
        let externalFile = externalDir.appendingPathComponent("out.txt")
        try "x\n".write(to: externalFile, atomically: true, encoding: .utf8)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        let session = TerminalSession(
            id: "s1", worktreeId: worktree.id, projectId: project.id,
            surface: surface, executable: "/bin/zsh", args: []
        )
        state.terminal.registry.register(session)

        let handled = state.routeTerminalOpenURL(rawURL: externalFile.path, sessionId: "s1")

        #expect(handled == false)
        #expect(state.tabs.tabs(forWorktree: worktree.id).allSatisfy { tab in
            if case .editor = tab { return false }
            return true
        })
    }

    @Test func routeTerminalOpenURLReturnsFalseForMissingFile() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "ghostty-missing")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        surface.setCurrentWorkingDirectory(worktree.path)
        let session = TerminalSession(
            id: "s1", worktreeId: worktree.id, projectId: project.id,
            surface: surface, executable: "/bin/zsh", args: []
        )
        state.terminal.registry.register(session)

        let handled = state.routeTerminalOpenURL(rawURL: "does-not-exist.md", sessionId: "s1")

        #expect(handled == false)
    }

    @Test func routeTerminalOpenURLReturnsFalseForInWorktreeSymlinkPointingOutside() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "ghostty-symlink-out")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let externalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ghostty-symlink-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDir) }
        let externalFile = externalDir.appendingPathComponent("escaped.txt")
        try "x\n".write(to: externalFile, atomically: true, encoding: .utf8)
        let linkURL = worktree.path.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalFile)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        surface.setCurrentWorkingDirectory(worktree.path)
        let session = TerminalSession(
            id: "s1", worktreeId: worktree.id, projectId: project.id,
            surface: surface, executable: "/bin/zsh", args: []
        )
        state.terminal.registry.register(session)

        let handled = state.routeTerminalOpenURL(rawURL: "escape.txt", sessionId: "s1")

        #expect(handled == false)
        #expect(state.tabs.tabs(forWorktree: worktree.id).allSatisfy { tab in
            if case .editor = tab { return false }
            return true
        })
    }

    @Test func routeTerminalOpenURLReturnsFalseForUnknownSession() async throws {
        let state = AppState()
        let handled = state.routeTerminalOpenURL(rawURL: "anything", sessionId: "missing")
        #expect(handled == false)
    }

    @Test func routeTerminalOpenURLReturnsFalseForDirectory() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "ghostty-dir")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let subdir = worktree.path.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        surface.setCurrentWorkingDirectory(worktree.path)
        let session = TerminalSession(
            id: "s1", worktreeId: worktree.id, projectId: project.id,
            surface: surface, executable: "/bin/zsh", args: []
        )
        state.terminal.registry.register(session)

        let handled = state.routeTerminalOpenURL(rawURL: "subdir", sessionId: "s1")

        #expect(handled == false)
    }

    @Test func routeTerminalOpenURLStripsTrailingPeriodWhenFileIsMissing() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "ghostty-trailing-dot")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let file = worktree.path.appendingPathComponent("hello.swift")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        surface.setCurrentWorkingDirectory(worktree.path)
        let session = TerminalSession(
            id: "s1", worktreeId: worktree.id, projectId: project.id,
            surface: surface, executable: "/bin/zsh", args: []
        )
        state.terminal.registry.register(session)

        let handled = state.routeTerminalOpenURL(rawURL: "hello.swift.", sessionId: "s1")

        #expect(handled == true)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let s) = $0 { return s.relativePath == "hello.swift" }
            return false
        })
    }

    @Test func routeTerminalOpenURLStripsTrailingPeriodWithPosition() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "ghostty-trailing-dot-pos")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let file = worktree.path.appendingPathComponent("hello.swift")
        try "first\nsecond\n".write(to: file, atomically: true, encoding: .utf8)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        surface.setCurrentWorkingDirectory(worktree.path)
        let session = TerminalSession(
            id: "s1", worktreeId: worktree.id, projectId: project.id,
            surface: surface, executable: "/bin/zsh", args: []
        )
        state.terminal.registry.register(session)

        let handled = state.routeTerminalOpenURL(rawURL: "hello.swift:2.", sessionId: "s1")

        #expect(handled == true)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let s) = $0 {
                return s.relativePath == "hello.swift"
                    && s.revealLine == 1
                    && s.revealCharacter == 0
            }
            return false
        })
    }

    @Test func routeTerminalOpenURLPrefersExactPathEndingWithPeriod() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "ghostty-exact-dot")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        // Create a file whose name actually ends with a period.
        let file = worktree.path.appendingPathComponent("Makefile.")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        surface.setCurrentWorkingDirectory(worktree.path)
        let session = TerminalSession(
            id: "s1", worktreeId: worktree.id, projectId: project.id,
            surface: surface, executable: "/bin/zsh", args: []
        )
        state.terminal.registry.register(session)

        let handled = state.routeTerminalOpenURL(rawURL: "Makefile.", sessionId: "s1")

        #expect(handled == true)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let s) = $0 { return s.relativePath == "Makefile." }
            return false
        })
    }

    @Test func makeCLICommandRouterOpensExternalFileOnOriginatingWorktreeAndSelectsIt() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "external")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let externalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cli-appstate-external-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDir) }
        let externalFile = externalDir.appendingPathComponent("external.txt")
        try "outside\n".write(to: externalFile, atomically: true, encoding: .utf8)
        state.selectedWorktreeId = nil

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { sessionId in
            sessionId == "s1" ? worktree.id : nil
        })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: [externalFile.path])))

        #expect(response == .ok)
        #expect(state.selectedWorktreeId == worktree.id)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let editor) = $0 {
                return editor.isExternal
                    && editor.externalAbsolutePath == externalFile.standardizedFileURL.path
                    && editor.relativePath.isEmpty
            }
            return false
        })
    }

    @Test func cliWorktreeSwitchFocusesMatchedWorktree() async throws {
        let (state, project, main) = try await makeStateWithWorktree(name: "switch")
        defer { try? FileManager.default.removeItem(at: main.path) }
        let other = Worktree(
            id: "other",
            projectId: project.id,
            name: "feature/review",
            branch: "feature/review",
            path: main.path.deletingLastPathComponent().appendingPathComponent("other"),
            status: .clean,
            lastActivity: Date()
        )
        state.projectsManager.insertOptimisticWorktree(other)

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in main.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.switch(target: "feature"))))

        #expect(response == .ok)
        #expect(state.selectedWorktreeId == other.id)
    }

    @Test func cliReviewOpensReviewChangesTab() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "review")
        defer { try? FileManager.default.removeItem(at: worktree.path) }

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in worktree.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .review(.localChanges(worktree: nil))))

        guard case .text(let lines) = response, lines.count == 2 else {
            Issue.record("expected two-line text response, got \(response)")
            return
        }
        let expectedSession = ReviewDraftSessionID.localChanges(
            worktreeID: worktree.id, worktreePath: worktree.path, scope: .all
        )
        let object = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: String]
        #expect(object?["session_id"] == expectedSession.rawValue)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .reviewChanges = $0 { return true }
            return false
        })
    }

    @Test func cliReviewFocusesOriginatingWorktreeBeforeOpeningReviewChanges() async throws {
        let (state, project, main) = try await makeStateWithWorktree(name: "review-focus")
        let otherPath = main.path.deletingLastPathComponent().appendingPathComponent("review-focus-other")
        defer {
            try? FileManager.default.removeItem(at: main.path)
            try? FileManager.default.removeItem(at: otherPath)
        }
        _ = try await Process.git(["worktree", "add", "-q", "-b", "review-focus-other", otherPath.path, "main"], cwd: main.path)
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let other = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.branch == "review-focus-other" })
        state.selectedWorktreeId = other.id

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in main.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .review(.localChanges(worktree: nil))))

        guard case .text(let lines) = response, lines.count == 2 else {
            Issue.record("expected two-line text response, got \(response)")
            return
        }
        let expectedSession = ReviewDraftSessionID.localChanges(
            worktreeID: main.id, worktreePath: main.path, scope: .all
        )
        let object = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: String]
        #expect(object?["session_id"] == expectedSession.rawValue)
        #expect(state.selectedWorktreeId == main.id)
        #expect(state.tabs.tabs(forWorktree: main.id).contains {
            if case .reviewChanges = $0 { return true }
            return false
        })
    }

    @Test func cliReviewProviderRejectsUnsupportedTargetBeforeRemoteLookup() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "review-provider-invalid")
        defer { try? FileManager.default.removeItem(at: worktree.path) }

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in worktree.id })
        // A target with whitespace fails classification entirely (it is not a
        // number/URL/range/revision candidate), so it is rejected up front —
        // before any git or code host remote lookup.
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .review(.target("not a review", worktree: nil))))

        #expect(response == .error(
            "unsupported review target 'not a review' — expected a PR/MR number or URL, "
                + "a commit range (base..head or base...head), a branch, or a revision"
        ))
    }

    @Test func cliReviewProviderReturnsErrorWhenNoCodeHostRemoteExists() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "review-provider-no-remote")
        defer { try? FileManager.default.removeItem(at: worktree.path) }

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in worktree.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .review(.target("123", worktree: nil))))

        #expect(response == .error("no code host remote found for this worktree"))
    }

    @Test func cliReviewProviderRejectsURLThatDoesNotMatchAnyCodeHostRemote() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "review-provider-mismatch")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        _ = try await Process.git(["remote", "add", "origin", "https://github.com/nacho/alas.git"], cwd: worktree.path)

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in worktree.id })
        let response = await router.handle(.init(
            version: 1,
            sessionId: "s1",
            cwd: nil,
            command: .review(.target("https://github.com/mrmans0n/alas/pull/580", worktree: nil))
        ))

        #expect(response == .error("review URL does not match this worktree's remote"))
    }

    @Test func cliReviewTwoDotRangeResolvesToCommitRangeWithResolvedSHAs() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "review-two-dot-range")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let file = worktree.path.appendingPathComponent("a.txt")
        try "second\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: worktree.path)
        _ = try await Process.git(["commit", "-q", "-m", "second"], cwd: worktree.path)
        let baseSHA = try await revParse("HEAD~1", at: worktree.path)
        let headSHA = try await revParse("HEAD", at: worktree.path)

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in worktree.id })
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.target("HEAD~1..HEAD", worktree: nil))
        ))

        guard case .text = response else {
            Issue.record("expected text response, got \(response)")
            return
        }
        let expectedTarget = ReviewSessionTarget.commitRange(
            worktreeID: worktree.id, repositoryPath: worktree.path, base: baseSHA, head: headSHA
        )
        let record = try #require(try ReviewSessionStore().load(id: expectedTarget.id))
        #expect(record.target.kind == .commitRange)
        #expect(record.target.payload == .commitRange(base: baseSHA, head: headSHA))
        // Pinned to resolved SHAs, not the floating ref strings.
        #expect(baseSHA != "HEAD~1")
        #expect(headSHA != "HEAD")
    }

    @Test func cliReviewTwoDotRangeOnRootCommitResolvesToEmptyTreeBase() async throws {
        // A repo with exactly one commit (the root commit) has no parent, so
        // `HEAD^` genuinely does not exist. The two-dot range base must fall
        // back to the canonical empty-tree SHA instead of failing to resolve
        // — see `GitService.resolveTwoDotLeftTree`.
        let (state, _, worktree) = try await makeStateWithWorktree(name: "review-root-commit-range")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let headSHA = try await revParse("HEAD", at: worktree.path)

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in worktree.id })
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.target("HEAD^..HEAD", worktree: nil))
        ))

        guard case .text = response else {
            Issue.record("expected text response, got \(response)")
            return
        }
        let emptyTreeSHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        let expectedTarget = ReviewSessionTarget.commitRange(
            worktreeID: worktree.id, repositoryPath: worktree.path, base: emptyTreeSHA, head: headSHA
        )
        let record = try #require(try ReviewSessionStore().load(id: expectedTarget.id))
        #expect(record.target.kind == .commitRange)
        #expect(record.target.payload == .commitRange(base: emptyTreeSHA, head: headSHA))
    }

    @Test func cliReviewThreeDotRangeResolvesToBranchTarget() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "review-three-dot-range")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let file = worktree.path.appendingPathComponent("a.txt")
        try "second\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "a.txt"], cwd: worktree.path)
        _ = try await Process.git(["commit", "-q", "-m", "second"], cwd: worktree.path)
        let baseSHA = try await revParse("HEAD~1", at: worktree.path)
        let headSHA = try await revParse("HEAD", at: worktree.path)

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in worktree.id })
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.target("HEAD~1...HEAD", worktree: nil))
        ))

        guard case .text = response else {
            Issue.record("expected text response, got \(response)")
            return
        }
        let expectedTarget = ReviewSessionTarget.branch(
            worktreeID: worktree.id, repositoryPath: worktree.path, base: baseSHA, head: headSHA
        )
        let record = try #require(try ReviewSessionStore().load(id: expectedTarget.id))
        #expect(record.target.kind == .branch)
        #expect(record.target.payload == .branch(base: baseSHA, head: headSHA))
    }

    @Test func cliReviewBareLocalBranchIsReviewedAgainstBaseWithPinnedSHAs() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "review-local-branch")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let mainSHA = try await revParse("main", at: worktree.path)
        _ = try await Process.git(["checkout", "-q", "-b", "feature-local"], cwd: worktree.path)
        let file = worktree.path.appendingPathComponent("feature.txt")
        try "feature\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "feature.txt"], cwd: worktree.path)
        _ = try await Process.git(["commit", "-q", "-m", "feature commit"], cwd: worktree.path)
        let featureSHA = try await revParse("feature-local", at: worktree.path)

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in worktree.id })
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.target("feature-local", worktree: nil))
        ))

        guard case .text = response else {
            Issue.record("expected text response, got \(response)")
            return
        }
        let expectedTarget = ReviewSessionTarget.branch(
            worktreeID: worktree.id, repositoryPath: worktree.path, base: mainSHA, head: featureSHA
        )
        let record = try #require(try ReviewSessionStore().load(id: expectedTarget.id))
        #expect(record.target.kind == .branch)
        #expect(record.target.payload == .branch(base: mainSHA, head: featureSHA))
        // Pinned to resolved SHAs, not the floating branch names.
        #expect(mainSHA != "main")
        #expect(featureSHA != "feature-local")
    }

    // Regression test for a bug where a bare revision matching a
    // remote-tracking branch name (which used to be classified as "a local
    // branch" because the old check used `GitService.branches(at:)`, the
    // union of local + remote-tracking branches) was misrouted into the
    // branch-vs-base flow. It must be treated as a single-commit revision.
    @Test func cliReviewBareRemoteTrackingBranchIsNotTreatedAsLocalBranch() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "review-remote-branch")
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cli-appstate-review-remote-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: worktree.path)
            try? FileManager.default.removeItem(at: remote)
        }
        _ = try await Process.git(["checkout", "-q", "-b", "develop"], cwd: worktree.path)
        let file = worktree.path.appendingPathComponent("develop.txt")
        try "develop\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "develop.txt"], cwd: worktree.path)
        _ = try await Process.git(["commit", "-q", "-m", "develop commit"], cwd: worktree.path)
        _ = try await Process.git(["init", "--bare", "-q", remote.path], cwd: nil)
        _ = try await Process.git(["remote", "add", "origin", remote.path], cwd: worktree.path)
        _ = try await Process.git(["push", "-q", "origin", "main:main"], cwd: worktree.path)
        _ = try await Process.git(["push", "-q", "origin", "develop:review/remote-only"], cwd: worktree.path)
        _ = try await Process.git(["fetch", "-q", "origin"], cwd: worktree.path)
        _ = try await Process.git(["checkout", "-q", "main"], cwd: worktree.path)
        let remoteRef = "origin/review/remote-only"
        let remoteSHA = try await revParse(remoteRef, at: worktree.path)

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in worktree.id })
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.target(remoteRef, worktree: nil))
        ))

        guard case .text = response else {
            Issue.record("expected text response, got \(response)")
            return
        }
        let expectedTarget = ReviewSessionTarget.commit(
            worktreeID: worktree.id, repositoryPath: worktree.path, sha: remoteSHA, title: "irrelevant"
        )
        let record = try #require(try ReviewSessionStore().load(id: expectedTarget.id))
        #expect(record.target.kind == .commit)
        #expect(record.target.payload == .commit(sha: remoteSHA))
    }

    @Test func cliReviewUnresolvableBareRevisionProducesDescriptiveError() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "review-unresolvable")
        defer { try? FileManager.default.removeItem(at: worktree.path) }

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in worktree.id })
        let response = await router.handle(.init(
            version: 1, sessionId: "s1", cwd: nil,
            command: .review(.target("totally-not-a-real-ref-xyz", worktree: nil))
        ))

        #expect(response == .error(
            "could not resolve review target 'totally-not-a-real-ref-xyz' in worktree '\(worktree.branch)' "
                + "(not a PR number/URL, local branch, or revision)"
        ))
    }

    private func revParse(_ ref: String, at path: URL) async throws -> String {
        let result = try await Process.git(["rev-parse", ref], cwd: path)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func cliWorktreeNewStartsCreation() async throws {
        let (state, project, main) = try await makeStateWithWorktree(name: "new")
        let destinationRoot = main.path.deletingLastPathComponent()
        let createdPath = destinationRoot.appendingPathComponent("test-feature-cli")
        defer {
            try? FileManager.default.removeItem(at: main.path)
            try? FileManager.default.removeItem(at: createdPath)
        }
        state.config.worktrees.rootPath = main.path.deletingLastPathComponent().path
        state.config.worktrees.pathTemplate = "{worktreeRoot}/{repo}-{branch}"

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in main.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.new(branch: "feature/cli", base: "missing-base"))))

        let destination = WorktreePathTemplateRenderer.render(
            template: state.config.worktrees.pathTemplate,
            worktreeRoot: state.config.worktrees.rootPath,
            repoName: project.name,
            branch: "feature/cli"
        )
        let canonicalDestination = destination
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(destination.lastPathComponent)
        let createdId = Worktree.makeId(path: canonicalDestination)
        #expect(response == .text(["creating feature/cli at \(destination.path)"]))
        #expect(state.projectsManager.operationState(forWorktreeId: createdId, projectId: project.id) == .creating)
        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == createdId })
    }

    @Test func cliWorktreeNewRejectsExistingDestination() async throws {
        let (state, project, main) = try await makeStateWithWorktree(name: "new-existing")
        defer { try? FileManager.default.removeItem(at: main.path) }
        state.config.worktrees.rootPath = main.path.deletingLastPathComponent().path
        state.config.worktrees.pathTemplate = "{worktreeRoot}/{branch}"
        let existingBranch = main.path.lastPathComponent

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in main.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.new(branch: existingBranch, base: "main"))))

        #expect(response == .error("A worktree already exists at this path."))
        #expect(state.projectsManager.worktrees(projectId: project.id).filter { $0.id == main.id }.count == 1)
    }

    @Test func cliWorktreeNewRejectsExistingDirectoryOnDisk() async throws {
        let (state, _, main) = try await makeStateWithWorktree(name: "new-existing-dir")
        let existingPath = main.path.deletingLastPathComponent().appendingPathComponent("already-there")
        defer {
            try? FileManager.default.removeItem(at: main.path)
            try? FileManager.default.removeItem(at: existingPath)
        }
        try FileManager.default.createDirectory(at: existingPath, withIntermediateDirectories: true)
        state.config.worktrees.rootPath = main.path.deletingLastPathComponent().path
        state.config.worktrees.pathTemplate = "{worktreeRoot}/{branch}"

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in main.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.new(branch: "already-there", base: "main"))))

        #expect(response == .error("A worktree already exists at this path."))
    }

    @Test func cliWorktreeNewUsesDialogPreferredBaseWhenBaseIsOmitted() async throws {
        let (state, project, main) = try await makeStateWithWorktree(name: "new-default-base", initialBranch: "master")
        let destinationRoot = main.path.deletingLastPathComponent()
        let createdPath = destinationRoot.appendingPathComponent("from-master")
        defer {
            try? FileManager.default.removeItem(at: main.path)
            try? FileManager.default.removeItem(at: createdPath)
        }
        state.config.worktrees.rootPath = destinationRoot.path
        state.config.worktrees.pathTemplate = "{worktreeRoot}/{branch}"
        state.config.worktrees.baseBranch = "stale-default"

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in main.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.new(branch: "from-master", base: nil))))

        let canonicalCreatedPath = createdPath
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(createdPath.lastPathComponent)
        let createdId = Worktree.makeId(path: canonicalCreatedPath)
        #expect(response == .text(["creating from-master at \(createdPath.path)"]))
        for _ in 0..<100 {
            if state.projectsManager.worktrees(projectId: project.id).contains(where: { $0.id == createdId }) &&
                state.projectsManager.operationState(forWorktreeId: createdId, projectId: project.id) == nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(state.projectsManager.operationState(forWorktreeId: createdId, projectId: project.id) == nil)
        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == createdId })
    }

    @Test func cliWorktreeDeleteMarksMatchedWorktreeDeleting() async throws {
        let (state, project, main) = try await makeStateWithWorktree(name: "delete")
        let worktreePath = main.path.deletingLastPathComponent().appendingPathComponent("delete-target")
        defer {
            try? FileManager.default.removeItem(at: main.path)
            try? FileManager.default.removeItem(at: worktreePath)
        }
        _ = try await Process.git(["worktree", "add", "-q", "-b", "delete-target", worktreePath.path, "main"], cwd: main.path)
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let target = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.branch == "delete-target" })

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in main.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.delete(target: "delete-target", force: false, keepBranch: true))))

        #expect(response == .ok)
        #expect(state.projectsManager.operationState(forWorktreeId: target.id, projectId: project.id) == .deleting(projectId: project.id))
    }

    @Test func cliWorktreeDeleteIsIdempotentWhileDeleting() async throws {
        let (state, project, main) = try await makeStateWithWorktree(name: "delete-idempotent")
        let target = Worktree(
            id: "deleting-target",
            projectId: project.id,
            name: "feature/delete",
            branch: "feature/delete",
            path: main.path.deletingLastPathComponent().appendingPathComponent("deleting-target"),
            status: .clean,
            lastActivity: Date()
        )
        defer { try? FileManager.default.removeItem(at: main.path) }
        state.projectsManager.insertOptimisticWorktree(target)
        state.projectsManager.setOperationState(forWorktreeId: target.id, projectId: project.id, state: .deleting(projectId: project.id))

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in main.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.delete(target: "feature/delete", force: true, keepBranch: true))))

        #expect(response == .ok)
        #expect(state.projectsManager.operationState(forWorktreeId: target.id, projectId: project.id) == .deleting(projectId: project.id))
    }

    @Test func cliWorktreeDeleteForceClearsStalePendingForceState() async throws {
        let (state, project, main) = try await makeStateWithWorktree(name: "delete-force")
        let worktreePath = main.path.deletingLastPathComponent().appendingPathComponent("delete-force-target")
        defer {
            try? FileManager.default.removeItem(at: main.path)
            try? FileManager.default.removeItem(at: worktreePath)
        }
        _ = try await Process.git(["worktree", "add", "-q", "-b", "delete-force-target", worktreePath.path, "main"], cwd: main.path)
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let target = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.branch == "delete-force-target" })
        state.pendingForceDeleteWorktree = AppState.PendingForceDeleteWorktree(
            id: target.id,
            branch: target.branch,
            projectId: target.projectId,
            repoPath: main.path,
            worktreePath: target.path,
            deleteBranchIfMerged: false,
            removedIndex: 1
        )

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in main.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.delete(target: "delete-force-target", force: true, keepBranch: true))))

        #expect(response == .ok)
        #expect(state.pendingForceDeleteWorktree == nil)
        #expect(state.projectsManager.operationState(forWorktreeId: target.id, projectId: project.id) == .deleting(projectId: project.id))
    }

    /// Regression: a CLI delete that dismisses a leftover `.preparingDelete`
    /// claim from an unanswered in-app dialog must actually release it, not
    /// just discard `pendingForceDeleteWorktree`. Otherwise the row stays
    /// blocked from new session admission forever — nothing else clears a
    /// bare `.preparingDelete` claim.
    @Test func cliWorktreeDeleteReleasesStalePreparingDeleteClaim() async throws {
        let (state, project, main) = try await makeStateWithWorktree(name: "delete-stale-claim")
        let worktreePath = main.path.deletingLastPathComponent().appendingPathComponent("delete-stale-claim-target")
        defer {
            try? FileManager.default.removeItem(at: main.path)
            try? FileManager.default.removeItem(at: worktreePath)
        }
        _ = try await Process.git(["worktree", "add", "-q", "-b", "delete-stale-claim-target", worktreePath.path, "main"], cwd: main.path)
        try "dirty".write(to: worktreePath.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let target = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.branch == "delete-stale-claim-target" })

        state.projectsManager.setOperationState(forWorktreeId: target.id, projectId: project.id, state: .preparingDelete)
        state.pendingForceDeleteWorktree = AppState.PendingForceDeleteWorktree(
            id: target.id,
            branch: target.branch,
            projectId: target.projectId,
            repoPath: main.path,
            worktreePath: target.path,
            deleteBranchIfMerged: false,
            removedIndex: 1
        )

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in main.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.delete(target: "delete-stale-claim-target", force: false, keepBranch: true))))

        guard case .error = response else {
            Issue.record("Expected an error response for an unforced dirty delete")
            return
        }
        #expect(state.pendingForceDeleteWorktree == nil)
        #expect(state.projectsManager.operationState(forWorktreeId: target.id, projectId: project.id) == nil)
    }

    /// Regression: a `.preparingDelete` claim with no matching
    /// `pendingForceDeleteWorktree` belongs to the live first confirmation
    /// dialog (`beginDeleteWorktree`'s blocking `NSAlert`, whose nested run
    /// loop is exactly how this CLI call can run while that alert is still
    /// up) — not a stale force prompt. The CLI must refuse rather than
    /// clear that claim and race the open dialog's own eventual decision.
    @Test func cliWorktreeDeleteRefusesWhenFirstDialogClaimIsLive() async throws {
        let (state, project, main) = try await makeStateWithWorktree(name: "delete-live-dialog")
        let worktreePath = main.path.deletingLastPathComponent().appendingPathComponent("delete-live-dialog-target")
        defer {
            try? FileManager.default.removeItem(at: main.path)
            try? FileManager.default.removeItem(at: worktreePath)
        }
        _ = try await Process.git(["worktree", "add", "-q", "-b", "delete-live-dialog-target", worktreePath.path, "main"], cwd: main.path)
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let target = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.branch == "delete-live-dialog-target" })

        state.projectsManager.setOperationState(forWorktreeId: target.id, projectId: project.id, state: .preparingDelete)
        #expect(state.pendingForceDeleteWorktree == nil)

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in main.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.delete(target: "delete-live-dialog-target", force: true, keepBranch: true))))

        guard case .error = response else {
            Issue.record("Expected the CLI to refuse rather than race the live dialog")
            return
        }
        #expect(state.projectsManager.operationState(forWorktreeId: target.id, projectId: project.id) == .preparingDelete)
    }

    /// Regression: a pending force prompt belongs to one project's worktree.
    /// A worktree id is its path, so a CLI delete for a same-path checkout
    /// under *another* project must not discard that prompt — which would
    /// leave the other project's `.preparingDelete` claim with no prompt left
    /// able to confirm or cancel it.
    @Test func cliDeleteUnderAnotherProjectKeepsADuplicateIDsPendingForcePrompt() async throws {
        let sharedID = "/srv/checkouts/member"
        let otherProject = ProjectConfig(
            id: "other-project",
            name: "Other",
            path: "/repos/other",
            color: "#fff",
            addedAt: .distantPast,
            host: "other-host"
        )
        // Both projects are seeded through the store, which is how AppState
        // takes its project list.
        var store = MemoryStore()
        store.projectsFile = ProjectsFile(projects: [otherProject])
        let state = AppState(store: store)
        let repo = try await makeRepo(name: "delete-pending-scope")
        defer { try? FileManager.default.removeItem(at: repo) }
        let project = try await state.projectsManager.addProject(path: repo, displayName: "test", color: "#000000")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let otherRow = Worktree(
            id: sharedID,
            projectId: otherProject.id,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: sharedID),
            status: .clean,
            lastActivity: .distantPast
        )
        state.projectsManager.insertOptimisticWorktree(otherRow)
        state.projectsManager.setOperationState(
            forWorktreeId: otherRow.id,
            projectId: otherProject.id,
            state: .preparingDelete
        )
        state.pendingForceDeleteWorktree = AppState.PendingForceDeleteWorktree(
            id: sharedID,
            branch: otherRow.branch,
            projectId: otherProject.id,
            repoPath: URL(fileURLWithPath: otherProject.path),
            worktreePath: otherRow.path,
            deleteBranchIfMerged: false,
            removedIndex: 0
        )

        // A worktree in *this* project that happens to share the same
        // path-derived id.
        let thisProjectRow = Worktree(
            id: sharedID,
            projectId: project.id,
            name: "feature",
            branch: "feature",
            path: URL(fileURLWithPath: "/repos/test/feature"),
            status: .clean,
            lastActivity: .distantPast
        )
        state.projectsManager.insertOptimisticWorktree(thisProjectRow)

        _ = await state.cliDeleteWorktree(thisProjectRow, force: true, keepBranch: true)

        // The other project's prompt and claim survive this project's delete.
        #expect(state.pendingForceDeleteWorktree?.projectId == otherProject.id)
        #expect(state.projectsManager.operationState(
            forWorktreeId: sharedID,
            projectId: otherProject.id
        ) == .preparingDelete)
    }

    /// A worktree owner carries only the path-derived id, so an owner-based
    /// ACP creation must be gated by the caller's project. Re-resolving the
    /// first project that lists that id reads that project's claim instead:
    /// here project B's checkout is deleting while project A lists the same
    /// path and is focused and clean, so an id-only lookup admits a session
    /// into the deleting checkout — and blocks the clean one.
    @Test func ownerBasedACPCreationReadsTheCallersProjectClaim() async throws {
        let sharedID = "/srv/checkouts/member"
        // Seeded in this order, so project A is the first match for the id.
        let project = ProjectConfig(
            id: "clean-project",
            name: "Clean",
            path: "/repos/clean",
            color: "#5fb7c4",
            addedAt: .distantPast
        )
        let otherProject = ProjectConfig(
            id: "other-project",
            name: "Other",
            path: "/repos/other",
            color: "#fff",
            addedAt: .distantPast,
            host: "other-host"
        )
        var store = MemoryStore()
        store.projectsFile = ProjectsFile(projects: [project, otherProject])
        let state = AppState(store: store)

        // The focused, clean project's row at the shared id.
        let thisProjectRow = Worktree(
            id: sharedID,
            projectId: project.id,
            name: "feature",
            branch: "feature",
            path: URL(fileURLWithPath: sharedID),
            status: .clean,
            lastActivity: .distantPast
        )
        state.projectsManager.insertOptimisticWorktree(thisProjectRow)
        state.focusGlobalWorktree(id: sharedID, projectId: project.id)
        // The other project's row at the same id, deleting.
        let otherRow = Worktree(
            id: sharedID,
            projectId: otherProject.id,
            name: "member",
            branch: "member",
            path: URL(fileURLWithPath: sharedID),
            status: .clean,
            lastActivity: .distantPast
        )
        state.projectsManager.insertOptimisticWorktree(otherRow)
        state.projectsManager.setOperationState(
            forWorktreeId: sharedID,
            projectId: otherProject.id,
            state: .deleting(projectId: otherProject.id)
        )
        // Materialize the owner's manager the way opening the launcher does.
        _ = state.acpManager(for: otherRow)

        // A caller holding the deleting project's checkout is refused.
        let admittedForDeletingProject = state.openNewACPSession(
            agentID: "test-agent",
            owner: .worktree(sharedID),
            projectId: otherProject.id
        )
        #expect(admittedForDeletingProject == nil)

        // The same call for the clean project is admitted, so the refusal
        // above is that project's claim and not a missing manager or agent.
        let admittedForCleanProject = state.openNewACPSession(
            agentID: "test-agent",
            owner: .worktree(sharedID),
            projectId: project.id
        )
        #expect(admittedForCleanProject != nil)
    }

    /// Regression test for the review palette ignoring a per-worktree
    /// base-branch override: a worktree whose right pane is already loaded
    /// (e.g. because the ReviewChanges tab that's opening the palette is
    /// rendering it) can have picked a base branch other than the global
    /// `config.worktrees.baseBranch` default. `reviewTargetPaletteEnvironment
    /// ().loadCommitsAhead` must honor that already-loaded override instead
    /// of always comparing against the global default.
    @Test func reviewPaletteLoadCommitsAheadRespectsAnAlreadyLoadedBaseBranchOverride() async throws {
        let (state, project, main) = try await makeStateWithWorktree(name: "palette-base-override")
        defer { try? FileManager.default.removeItem(at: main.path) }

        // `main` already has one commit from `makeRepo`. Build:
        //   shared  = main + one commit (the override base)
        //   feature = shared + two more commits, checked out in the worktree
        // Ahead of `main` (the global default) is 3 commits; ahead of
        // `shared` (the per-worktree override) is only 2.
        _ = try await Process.git(["checkout", "-b", "shared"], cwd: main.path)
        try "b\n".write(to: main.path.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: main.path)
        _ = try await Process.git(["commit", "-q", "-m", "shared commit"], cwd: main.path)

        _ = try await Process.git(["checkout", "-b", "feature"], cwd: main.path)
        try "c\n".write(to: main.path.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: main.path)
        _ = try await Process.git(["commit", "-q", "-m", "feature commit 1"], cwd: main.path)
        try "d\n".write(to: main.path.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["add", "."], cwd: main.path)
        _ = try await Process.git(["commit", "-q", "-m", "feature commit 2"], cwd: main.path)

        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let worktree = try #require(
            state.projectsManager.worktrees(projectId: project.id).first { $0.branch == "feature" }
        )
        state.selectedWorktreeId = worktree.id

        #expect(state.config.worktrees.baseBranch == "main")

        // Simulate the worktree's right pane already having been activated
        // with the user having manually picked "shared" as its base branch.
        let rightPaneState = state.rightPaneStore.state(
            for: worktree,
            baseBranch: state.config.worktrees.baseBranch,
            comparisonMode: state.config.changes.comparisonMode
        )
        rightPaneState.selectBaseBranch("shared")
        #expect(rightPaneState.userOverrodeBaseBranch)

        let environment = state.reviewTargetPaletteEnvironment()
        let result = try await environment.loadCommitsAhead(worktree)

        #expect(result.comparisonRef == "shared")
        #expect(result.commits.count == 2)
    }
}
