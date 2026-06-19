import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateCLIRoutingTests {
    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cli-appstate-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    private func makeStateWithWorktree(name: String) async throws -> (AppState, ProjectConfig, Worktree) {
        let repo = try await makeRepo(name: name)
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
        let response = router.handle(.init(version: 1, sessionId: "s1", command: .open(paths: [file.path])))

        #expect(response == .ok)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let editor) = $0 { return editor.relativePath == "a.txt" }
            return false
        })
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
        let response = await handler(.init(version: 1, sessionId: "s1", command: .open(paths: [file.path])))

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
        let response = router.handle(.init(version: 1, sessionId: "s1", command: .open(paths: [externalFile.path])))

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
}
