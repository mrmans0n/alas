import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateCLIRoutingTests {
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

        let handled = state.routeTranscriptOpenURL(
            URL(string: "\(file.path):2")!,
            worktreeId: worktree.id
        )

        #expect(handled == true)
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

        let handled = state.routeTranscriptOpenURL(
            URL(string: "Package.swift:2")!,
            worktreeId: worktree.id
        )

        #expect(handled == true)
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
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .review(.localChanges)))

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
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .review(.localChanges)))

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
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .review(.provider(target: "not-a-review"))))

        #expect(response == .error("unsupported review URL"))
    }

    @Test func cliReviewProviderReturnsErrorWhenNoCodeHostRemoteExists() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "review-provider-no-remote")
        defer { try? FileManager.default.removeItem(at: worktree.path) }

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in worktree.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .review(.provider(target: "123"))))

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
            command: .review(.provider(target: "https://github.com/mrmans0n/alas/pull/580"))
        ))

        #expect(response == .error("review URL does not match this worktree's remote"))
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
        #expect(state.projectsManager.operationState(for: createdId) == .creating)
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
                state.projectsManager.operationState(for: createdId) == nil {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(state.projectsManager.operationState(for: createdId) == nil)
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
        #expect(state.projectsManager.operationState(for: target.id) == .deleting)
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
        state.projectsManager.setOperationState(id: target.id, state: .deleting)

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in main.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.delete(target: "feature/delete", force: true, keepBranch: true))))

        #expect(response == .ok)
        #expect(state.projectsManager.operationState(for: target.id) == .deleting)
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
            removedIndex: 1,
            reason: .dirty
        )

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { _ in main.id })
        let response = await router.handle(.init(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.delete(target: "delete-force-target", force: true, keepBranch: true))))

        #expect(response == .ok)
        #expect(state.pendingForceDeleteWorktree == nil)
        #expect(state.projectsManager.operationState(for: target.id) == .deleting)
    }
}
